import type postgres from "postgres";
import {
  type BillingManagementRepository,
  type BillingOperation,
  MONTHLY_PRICE,
} from "./billing_management.ts";
import { createPostgresBillingTransaction } from "./postgres_billing_repository.ts";
import { transitionSubscription } from "./subscription.ts";

function operation(row: Record<string, unknown>): BillingOperation {
  return {
    id: String(row.operation_id),
    requestID: String(row.request_id),
    orderID: String(row.provider_order_id),
    kind: row.kind as BillingOperation["kind"],
    state: row.state as BillingOperation["state"],
  };
}

async function lockAccount(connection: postgres.TransactionSql, userID: string) {
  const rows = await connection`select id from auth.users where id = ${userID} for update`;
  if (rows.length !== 1) throw new Error("account unavailable");
}

export function createPostgresBillingManagementRepository(
  sql: postgres.Sql,
): BillingManagementRepository {
  return {
    async snapshot(userID) {
      const [snapshot] = await sql.begin(async (connection) => {
        await lockAccount(connection, userID);
        const tx = createPostgresBillingTransaction(connection);
        const orderID = await tx.currentOrderForUser(userID);
        const rows = await connection`
          select * from private.billing_operations where user_id = ${userID}
          order by created_at, operation_id limit 20
        `;
        return [{
          subscription: orderID === null ? null : await tx.currentSubscription(orderID),
          operations: rows.map(operation),
        }];
      });
      return snapshot;
    },

    async prepare(userID, command, identifiers, now) {
      const [result] = await sql.begin(async (connection) => {
        await lockAccount(connection, userID);
        const previous = await connection`
          select * from private.billing_operations where user_id = ${userID}
            and request_id = ${command.requestID}
        `;
        if (previous.length) {
          const stored = operation(previous[0]);
          if (
            stored.kind !== command.kind ||
            (command.kind === "cancel" && stored.orderID !== command.orderID)
          ) {
            return [{ conflict: "request_conflict" as const }];
          }
          return [{ operation: stored, acquired: false }];
        }
        const orderID = command.kind === "checkout" ? identifiers.orderID : command.orderID;
        if (command.kind === "checkout") {
          const existing =
            await connection`select 1 from private.billing_orders where user_id = ${userID} limit 1`;
          if (existing.length) return [{ conflict: "existing_order" as const }];
          await connection`
            insert into private.billing_orders
              (provider, provider_order_id, user_id, expected_currency, expected_amount_minor)
            values ('ecpay', ${orderID}, ${userID}, ${MONTHLY_PRICE.currency}, ${MONTHLY_PRICE.amountMinor})
          `;
        } else {
          // Never acquire another account's lock for a caller-selected order.
          const owned = await connection`
            select 1 from private.billing_orders where provider = 'ecpay'
              and provider_order_id = ${orderID} and user_id = ${userID} for update
          `;
          if (!owned.length) return [{ conflict: "not_found" as const }];
          const tx = createPostgresBillingTransaction(connection);
          if (await tx.currentOrderForUser(userID) !== orderID) {
            return [{ conflict: "not_found" as const }];
          }
          const row = await tx.currentSubscription(orderID);
          if (!row || row.user_id !== userID) return [{ conflict: "not_found" as const }];
          if (row.status === "cancelled") return [{ alreadyCancelled: true as const }];
          if (row.status !== "active" && row.status !== "payment_failed") {
            return [{ conflict: "not_found" as const }];
          }
          const prior = await connection`
            select 1 from private.billing_operations where provider = 'ecpay'
              and provider_order_id = ${orderID} and kind = 'cancel'
          `;
          if (prior.length) return [{ conflict: "operation_exists" as const }];
        }
        const rows = await connection`
          insert into private.billing_operations
            (operation_id, user_id, request_id, provider_order_id, kind, created_at, updated_at)
          values (${identifiers.operationID}, ${userID}, ${command.requestID}, ${orderID},
            ${command.kind}, ${now.toISOString()}, ${now.toISOString()}) returning *
        `;
        return [{ operation: operation(rows[0]), acquired: true }];
      });
      return result;
    },

    async finish(userID, operationID, outcome, now) {
      const [result] = await sql.begin(async (connection) => {
        await lockAccount(connection, userID);
        const operations = await connection`
          select * from private.billing_operations
          where operation_id = ${operationID} and user_id = ${userID} for update
        `;
        if (!operations.length) throw new Error("operation unavailable");
        const stored = operation(operations[0]);
        if (stored.state !== "pending") return [stored];
        const tx = createPostgresBillingTransaction(connection);
        const authorization = await tx.authorizationForOrder(stored.orderID);
        if (authorization?.userID !== userID) throw new Error("order unavailable");
        let state: BillingOperation["state"] = outcome === "confirmed" ? "succeeded" : "unknown";
        if (outcome === "confirmed" && stored.kind === "cancel") {
          const previous = await tx.currentSubscription(stored.orderID);
          const event = {
            event_key: `management-${stored.id}`,
            kind: "cancellation_confirmed" as const,
            user_id: userID,
            provider_order_id: stored.orderID,
            occurred_at: now.toISOString(),
          };
          const next = transitionSubscription(previous, event, new Set());
          if (
            await tx.currentOrderForUser(userID) !== stored.orderID || next.result !== "applied" ||
            !next.row
          ) {
            state = "unknown";
          } else {
            const subscriptionID = await tx.saveSubscription(next.row);
            if (await tx.insertEventOnce("ecpay", event, subscriptionID) !== "inserted") {
              throw new Error("cancellation event conflict");
            }
          }
        }
        const updated = await connection`
          update private.billing_operations set state = ${state}, updated_at = ${now.toISOString()}
          where operation_id = ${operationID} and user_id = ${userID} returning *
        `;
        return [operation(updated[0])];
      });
      return result;
    },
  };
}
