import type postgres from "postgres";
import {
  type BillingEventRepository,
  type BillingEventTransaction,
  type BillingOrderAuthorization,
} from "./billing_event_processor.ts";
import type { SubscriptionRow } from "./subscription.ts";

function subscriptionRow(record: Record<string, unknown>): SubscriptionRow {
  const timestamp = (value: unknown) => value instanceof Date ? value.toISOString() : String(value);
  const revision = Number(record.revision);
  if (!Number.isSafeInteger(revision) || revision <= 0) {
    throw new Error("invalid subscription revision");
  }
  return {
    user_id: String(record.user_id),
    provider_order_id: String(record.provider_order_id),
    status: record.status as SubscriptionRow["status"],
    paid_from: timestamp(record.paid_from),
    paid_through: timestamp(record.paid_through),
    cancel_confirmed_at: record.cancel_confirmed_at === null
      ? null
      : timestamp(record.cancel_confirmed_at),
    revision,
  };
}

export function createPostgresBillingRepository(sql: postgres.Sql): BillingEventRepository {
  return {
    transaction<T>(work: (tx: BillingEventTransaction) => Promise<T>): Promise<T> {
      return sql.begin(async (connection) => ({
        value: await work(createPostgresBillingTransaction(connection)),
      })).then((result) => result.value);
    },
  };
}

export function createPostgresBillingTransaction(
  connection: postgres.TransactionSql,
): BillingEventTransaction {
  const tx: BillingEventTransaction = {
    async authorizationForOrder(orderID): Promise<BillingOrderAuthorization | null> {
      const initial = await connection`
              select user_id, expected_currency, expected_amount_minor
              from private.billing_orders
              where provider = 'ecpay' and provider_order_id = ${orderID}
            `;
      if (initial.length !== 1) return null;

      const owners = await connection`
              select id from auth.users where id = ${initial[0].user_id} for update
            `;
      if (owners.length !== 1) return null;

      const locked = await connection`
              select user_id, expected_currency, expected_amount_minor
              from private.billing_orders
              where provider = 'ecpay' and provider_order_id = ${orderID}
              for update
            `;
      if (
        locked.length !== 1 ||
        locked[0].user_id !== initial[0].user_id ||
        locked[0].expected_currency !== initial[0].expected_currency ||
        locked[0].expected_amount_minor !== initial[0].expected_amount_minor
      ) throw new Error("billing order changed while acquiring locks");

      const amountMinor = Number(locked[0].expected_amount_minor);
      if (!Number.isSafeInteger(amountMinor) || amountMinor <= 0) {
        throw new Error("invalid billing order amount");
      }
      return {
        userID: String(locked[0].user_id),
        currency: String(locked[0].expected_currency),
        amountMinor,
      };
    },

    async currentSubscription(orderID) {
      const rows = await connection`
              select user_id, provider_order_id, status, paid_from, paid_through,
                cancel_confirmed_at, revision
              from private.subscriptions
              where provider = 'ecpay' and provider_order_id = ${orderID}
            `;
      return rows.length === 0 ? null : subscriptionRow(rows[0]);
    },

    async currentOrderForUser(userID) {
      const rows = await connection`
              select provider_order_id from private.subscriptions
              where user_id = ${userID} and is_current = true limit 1
            `;
      return rows.length === 0 ? null : String(rows[0].provider_order_id);
    },

    async eventOrderID(provider, eventKey) {
      const rows = await connection`
              select s.provider_order_id
              from private.subscription_events e
              join private.subscriptions s using (subscription_id)
              where e.provider = ${provider} and e.provider_event_key = ${eventKey}
            `;
      return rows.length === 0 ? null : String(rows[0].provider_order_id);
    },

    async insertEventOnce(provider, event, subscriptionID) {
      const inserted = await connection`
              insert into private.subscription_events
                (subscription_id, provider, provider_event_key, event_kind, occurred_at)
              values (
                ${subscriptionID}, ${provider}, ${event.event_key}, ${event.kind},
                ${event.occurred_at}
              )
              on conflict (provider, provider_event_key) do nothing
              returning event_id
            `;
      if (inserted.length === 1) return "inserted";
      const existingOrderID = await tx.eventOrderID(provider, event.event_key);
      if (existingOrderID === null) {
        throw new Error("event conflict without a recorded order");
      }
      return { existingOrderID };
    },

    async saveSubscription(row) {
      const saved = await connection`
              insert into private.subscriptions
                (user_id, provider, provider_order_id, status, paid_from, paid_through,
                 cancel_confirmed_at, revision)
              values (
                ${row.user_id}, 'ecpay', ${row.provider_order_id}, ${row.status},
                ${row.paid_from}, ${row.paid_through}, ${row.cancel_confirmed_at}, ${row.revision}
              )
              on conflict (provider, provider_order_id) do update set
                status = excluded.status,
                paid_from = excluded.paid_from,
                paid_through = excluded.paid_through,
                cancel_confirmed_at = excluded.cancel_confirmed_at,
                revision = excluded.revision,
                updated_at = now()
              where private.subscriptions.user_id = excluded.user_id
                and private.subscriptions.revision + 1 = excluded.revision
              returning subscription_id
            `;
      if (saved.length !== 1) throw new Error("subscription write conflict");
      return String(saved[0].subscription_id);
    },
  };
  return tx;
}
