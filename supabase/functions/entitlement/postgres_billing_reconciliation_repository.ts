import type postgres from "postgres";
import {
  decideRecovery,
  type RecoveryEvidence,
  type RecoverySnapshot,
} from "./billing_reconciliation.ts";
import { applyVerifiedBillingEvent, DuplicateBillingEvent } from "./billing_event_processor.ts";
import { createPostgresBillingTransaction } from "./postgres_billing_repository.ts";
import { paymentFactsDigest } from "./ecpay_billing_normalizer.ts";
export type RecoveryResult = "applied" | "duplicate" | "needs_review" | "stale" | "unavailable";
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function hash(value: unknown): Promise<string> {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value))),
    ),
    (v) => v.toString(16).padStart(2, "0"),
  ).join("");
}
async function lockedSnapshot(
  connection: postgres.TransactionSql,
  userID: string,
  operationID: string,
): Promise<RecoverySnapshot | null> {
  if (!uuid.test(userID) || !uuid.test(operationID)) return null;
  const account = await connection`select id from auth.users where id=${userID} for update`;
  if (!account.length) return null;
  const initial =
    await connection`select provider_order_id from private.billing_operations where operation_id=${operationID} and user_id=${userID}`;
  if (!initial.length) return null;
  const owned =
    await connection`select * from private.billing_orders where provider='ecpay' and provider_order_id=${
      initial[0].provider_order_id
    } and user_id=${userID} for update`;
  if (!owned.length) return null;
  const rows =
    await connection`select * from private.billing_operations where operation_id=${operationID} and user_id=${userID} for update`;
  const r = rows[0];
  if (!r || r.provider_order_id !== initial[0].provider_order_id) return null;
  const tx = createPostgresBillingTransaction(connection);
  const operation = {
    id: String(r.operation_id),
    requestID: String(r.request_id),
    orderID: String(r.provider_order_id),
    kind: r.kind as "checkout" | "cancel",
    state: r.state as "pending" | "unknown" | "succeeded",
  };
  const subscription = await tx.currentSubscription(operation.orderID);
  const currentOrder = await tx.currentOrderForUser(userID);
  const stateToken = await hash([
    "recovery-state-v1",
    userID,
    operation,
    r.created_at,
    r.updated_at,
    subscription,
    currentOrder,
    owned[0].expected_currency,
    String(owned[0].expected_amount_minor),
  ]);
  return { userID, operation, subscription, stateToken };
}
async function evidenceDigest(e: RecoveryEvidence): Promise<string> {
  if (e.kind !== "order") return await hash(["recovery-evidence-v1", e.kind]);
  return await hash([
    "recovery-evidence-v1",
    e.merchantID,
    e.orderID,
    e.complete,
    e.execution,
    e.cancelledAt,
    [...e.payments].map((p) => [p.notification.eventKey, p.factsDigest]).sort((a, b) =>
      a[0].localeCompare(b[0])
    ),
  ]);
}
export function createPostgresBillingReconciliationRepository(sql: postgres.Sql) {
  return {
    snapshot(userID: string, operationID: string): Promise<RecoverySnapshot | null> {
      return sql.begin(async (c) => ({ value: await lockedSnapshot(c, userID, operationID) })).then(
        (r) => r.value,
      );
    },
    async apply(
      snapshot: RecoverySnapshot,
      evidence: RecoveryEvidence,
      observedAt: Date,
    ): Promise<RecoveryResult> {
      try {
        // Snapshot caller-owned objects before yielding; never trust a supplied
        // subscription or operation state for the decision made under locks.
        const input = structuredClone(snapshot),
          e = structuredClone(evidence),
          observed = observedAt.toISOString();
        if (e.kind === "order") {
          for (
            const p of e.payments
          ) {
            if (await paymentFactsDigest(p.notification) !== p.factsDigest) return "needs_review";
          }
        }
        const digest = await evidenceDigest(e);
        const result = await sql.begin(async (c) => {
          const fresh = await lockedSnapshot(c, input.userID, input.operation.id);
          if (!fresh || fresh.stateToken !== input.stateToken) {
            return { value: "stale" as RecoveryResult };
          }
          const existing =
            await c`select 1 from private.billing_recovery_audit where operation_id=${fresh.operation.id} and evidence_digest=${digest} and state_digest=${fresh.stateToken}`;
          if (existing.length) return { value: "duplicate" as RecoveryResult };
          const record = async (
            value: "applied" | "duplicate" | "needs_review",
            reason: string,
          ) => {
            await c`insert into private.billing_recovery_audit(operation_id,user_id,evidence_digest,state_digest,observed_at,result,reason)
              values(${fresh.operation.id},${fresh.userID},${digest},${fresh.stateToken},${observed},${value},${reason})`;
            return { value: value as RecoveryResult };
          };
          const tx = createPostgresBillingTransaction(c);
          const current = await tx.currentOrderForUser(fresh.userID);
          if (current !== null && current !== fresh.operation.orderID) {
            return await record("needs_review", "policy_conflict");
          }
          let remaining = e;
          if (e.kind === "order") {
            if (e.orderID !== fresh.operation.orderID) {
              return await record("needs_review", "invalid_evidence");
            }
            const auth = await tx.authorizationForOrder(e.orderID);
            if (auth?.userID !== fresh.userID) {
              return await record("needs_review", "invalid_evidence");
            }
            const payments = [];
            const seen = new Map<string, string>();
            for (const p of e.payments) {
              const n = p.notification;
              if (
                n.orderID !== e.orderID || n.currency !== auth.currency ||
                n.amountMinor !== auth.amountMinor
              ) return await record("needs_review", "invalid_evidence");
              if (seen.has(n.eventKey)) {
                if (seen.get(n.eventKey) !== p.factsDigest) {
                  return await record("needs_review", "conflicting_facts");
                }
                continue;
              }
              seen.set(n.eventKey, p.factsDigest);
              const prior = await tx.eventOrderID("ecpay", n.eventKey);
              if (prior !== null) {
                if (
                  prior !== n.orderID ||
                  await tx.eventFactsDigest("ecpay", n.eventKey) !== p.factsDigest
                ) return await record("needs_review", "conflicting_facts");
              } else payments.push(p);
            }
            remaining = {
              ...e,
              payments: payments.sort((a, b) =>
                Date.parse(a.notification.paidFrom!) - Date.parse(b.notification.paidFrom!)
              ),
            };
            if (
              fresh.operation.state === "succeeded" && fresh.operation.kind === "cancel" &&
              fresh.subscription?.status === "cancelled" && e.complete &&
              e.execution === "cancelled" &&
              e.cancelledAt === fresh.subscription.cancel_confirmed_at && payments.length === 0
            ) return await record("duplicate", "duplicate");
          }
          const decision = decideRecovery(fresh, remaining);
          if (decision.kind === "needs_review") {
            return await record("needs_review", decision.reason);
          }
          if (decision.kind === "payments") {
            const p = decision.payments[0];
            const applied = await applyVerifiedBillingEvent(tx, p.notification, p.factsDigest);
            if (applied !== "applied") throw new Error("recovery payment write conflict");
            return await record("applied", "payment");
          }
          if (decision.kind === "cancellation") {
            const n = {
              provider: "ecpay" as const,
              eventKey: `recovery-cancel:${fresh.operation.id}`,
              kind: "cancellation_confirmed" as const,
              orderID: fresh.operation.orderID,
              occurredAt: decision.occurredAt,
            };
            const applied = await applyVerifiedBillingEvent(
              tx,
              n,
              await hash(["recovery-cancel-v1", n.orderID, n.eventKey, n.occurredAt]),
            );
            if (applied !== "applied") throw new Error("recovery cancellation write conflict");
          } else if (fresh.operation.state === "succeeded") {
            return await record("duplicate", "duplicate");
          }
          await c`update private.billing_operations set state='succeeded',updated_at=${observed} where operation_id=${fresh.operation.id} and user_id=${fresh.userID}`;
          return await record(
            "applied",
            decision.kind === "cancellation" ? "cancellation" : "checkout",
          );
        });
        return result.value;
      } catch (error) {
        return error instanceof DuplicateBillingEvent ? "needs_review" : "unavailable";
      }
    },
  };
}
