import type postgres from "postgres";
import { databaseTest, withAccount } from "./test-fixtures/local_database.ts";
import { createPostgresBillingManagementRepository } from "./postgres_billing_management_repository.ts";
import { createPostgresBillingRepository } from "./postgres_billing_repository.ts";
import { createPostgresBillingReconciliationRepository } from "./postgres_billing_reconciliation_repository.ts";
import {
  processBillingNotification,
  type VerifiedBillingNotification,
} from "./billing_event_processor.ts";
import { validateMockQuery } from "./billing_reconciliation.ts";
import { paymentFactsDigest } from "./ecpay_billing_normalizer.ts";

function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`${JSON.stringify(a)} != ${JSON.stringify(b)}`);
  }
}
const now = new Date("2026-10-15T00:00:00Z");

databaseTest(
  "succeeded checkout still recovers a later missing renewal",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      const first = { ...t.evidence, payments: t.evidence.payments.slice(0, 1) };
      equal(await t.repo.apply(await t.get(), first, now), "applied");
      equal(await t.repo.apply(await t.get(), first, now), "applied");
      equal((await t.get()).operation.state, "succeeded");
      equal(await t.repo.apply(await t.get(), t.evidence, now), "applied");
      equal((await t.get()).subscription?.revision, 2);
    }),
);
databaseTest(
  "cancellation audit failure rolls back event subscription and operation together",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      const p = t.evidence.payments[0];
      await callback(sql, p.notification, p.factsDigest);
      const id = crypto.randomUUID();
      await t.management.prepare(
        user,
        { kind: "cancel", requestID: crypto.randomUUID(), orderID: t.orderID },
        { operationID: id, orderID: t.orderID },
        now,
      );
      const s = await t.get(id);
      await sql`create function private.test_recovery_cancel_failure() returns trigger language plpgsql as 'begin raise exception ''forced test rollback''; end;'`;
      await sql`create trigger test_recovery_cancel_failure before insert on private.billing_recovery_audit for each row execute function private.test_recovery_cancel_failure()`;
      try {
        equal(
          await t.repo.apply(s, {
            ...t.evidence,
            execution: "cancelled",
            cancelledAt: now.toISOString(),
            payments: [],
          }, now),
          "unavailable",
        );
        equal(await t.get(id), s);
        equal(await counts(sql, user), { events: 1, audits: 0 });
      } finally {
        await sql`drop trigger test_recovery_cancel_failure on private.billing_recovery_audit`;
        await sql`drop function private.test_recovery_cancel_failure()`;
      }
    }),
);
databaseTest(
  "invalid digest cannot create an event",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      const p = t.evidence.payments[0];
      equal(await callback(sql, p.notification, "invalid"), "rejected");
      equal(
        await t.repo.apply(await t.get(), {
          ...t.evidence,
          payments: [{ ...p, factsDigest: "0".repeat(64) }],
        }, now),
        "needs_review",
      );
      equal(await counts(sql, user), { events: 0, audits: 0 });
    }),
);
async function setup(sql: postgres.Sql, userID: string) {
  const management = createPostgresBillingManagementRepository(sql);
  const operationID = crypto.randomUUID();
  const orderID = "r" + crypto.randomUUID().replaceAll("-", "").slice(0, 19);
  await management.prepare(userID, { kind: "checkout", requestID: crypto.randomUUID() }, {
    operationID,
    orderID,
  }, now);
  await management.finish(userID, operationID, "unknown", now);
  const repo = createPostgresBillingReconciliationRepository(sql);
  const get = async (id = operationID) => {
    const s = await repo.snapshot(userID, id);
    if (!s) throw new Error("missing snapshot");
    return s;
  };
  const evidence = await validateMockQuery(
    new TextEncoder().encode(JSON.stringify({
      mode: "mock",
      kind: "order",
      merchantID: "1234567",
      orderID,
      complete: true,
      execution: "active",
      cancelledAt: null,
      authorizations: [1, 2, 3].map((n) => ({
        authorizationID: String(n),
        amountTWD: "80",
        occurredAt: `2026-${String(n + 9).padStart(2, "0")}-01T00:00:00Z`,
        outcome: "paid",
        simulated: false,
      })),
    })),
    { userID, merchantID: "1234567", orderID, currency: "TWD", amountMinor: 8000 },
    ({ authorizationID }) => {
      const n = Number(authorizationID);
      return Promise.resolve({
        from: new Date(Date.UTC(2026, 8 + n, 1)).toISOString(),
        through: new Date(Date.UTC(2026, 9 + n, 1)).toISOString(),
      });
    },
  );
  if (evidence.kind !== "order") throw new Error("missing evidence");
  return { management, operationID, orderID, repo, get, evidence };
}
function callback(
  sql: postgres.Sql,
  notification: VerifiedBillingNotification,
  factsDigest?: string,
) {
  return processBillingNotification(new Uint8Array([1]), new Headers(), {
    repository: createPostgresBillingRepository(sql),
    verifier: { verify: () => Promise.resolve(notification) },
    factsDigest,
  });
}
async function counts(sql: postgres.Sql, userID: string) {
  const rows =
    await sql`select (select count(*)::int from private.subscription_events e join private.subscriptions s using(subscription_id) where s.user_id=${userID}) as events,(select count(*)::int from private.billing_recovery_audit where user_id=${userID}) as audits`;
  return rows[0];
}
databaseTest(
  "recovery replay skips committed prefix finalizes and supports succeeded checkout",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      for (let n = 1; n <= 3; n++) {
        equal(await t.repo.apply(await t.get(), t.evidence, now), "applied");
        const s = await t.get();
        equal(s.subscription?.revision, n);
        equal(s.operation.state, "unknown");
      }
      equal(await t.repo.apply(await t.get(), t.evidence, now), "applied");
      equal((await t.get()).operation.state, "succeeded");
      equal(await t.repo.apply(await t.get(), t.evidence, now), "duplicate");
      equal((await counts(sql, user)).events, 3);
      equal((await t.get()).subscription?.revision, 3);
    }),
);
databaseTest(
  "callback digest same facts duplicate changed or legacy facts require review",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      const p = t.evidence.payments[0];
      equal(await callback(sql, p.notification, p.factsDigest), "applied");
      equal(await callback(sql, p.notification, p.factsDigest), "duplicate");
      const changed = { ...p.notification, occurredAt: "2026-10-01T00:00:01Z" };
      equal(await callback(sql, changed, await paymentFactsDigest(changed)), "reconcile");
      await sql`update private.subscription_events set facts_digest=null where provider_event_key=${p.notification.eventKey}`;
      equal(await callback(sql, p.notification, p.factsDigest), "reconcile");
      equal(await t.repo.apply(await t.get(), t.evidence, now), "needs_review");
      equal((await t.get()).subscription?.revision, 1);
    }),
);
databaseTest(
  "conflicting replay prefix prevents later payment and deduplicates audit",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      equal(await t.repo.apply(await t.get(), t.evidence, now), "applied");
      const p = t.evidence.payments[0];
      const notification = { ...p.notification, occurredAt: "2026-10-01T00:00:01Z" };
      const evidence = {
        ...t.evidence,
        payments: [
          { notification, factsDigest: await paymentFactsDigest(notification) },
          ...t.evidence.payments.slice(1),
        ],
      };
      const s = await t.get();
      equal(await t.repo.apply(s, evidence, now), "needs_review");
      const before = await counts(sql, user);
      equal(await t.repo.apply(s, evidence, new Date(now.getTime() + 1000)), "duplicate");
      equal(await counts(sql, user), before);
      equal((await t.get()).subscription?.revision, 1);
    }),
);
databaseTest(
  "callback versus recovery concurrency grants first period only once",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      const p = t.evidence.payments[0];
      const s = await t.get();
      const results = await Promise.all([
        t.repo.apply(s, { ...t.evidence, payments: [p] }, now),
        callback(sql, p.notification, p.factsDigest),
      ]);
      equal(results.includes("applied"), true);
      equal((await t.get()).subscription?.revision, 1);
      equal((await counts(sql, user)).events, 1);
    }),
);
databaseTest(
  "two cancellation recovery workers produce one revision and one cancellation event",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      const p = t.evidence.payments[0];
      await callback(sql, p.notification, p.factsDigest);
      const id = crypto.randomUUID();
      await t.management.prepare(
        user,
        { kind: "cancel", requestID: crypto.randomUUID(), orderID: t.orderID },
        { operationID: id, orderID: t.orderID },
        now,
      );
      await t.management.finish(user, id, "unknown", now);
      const s = await t.get(id);
      const e = {
        ...t.evidence,
        execution: "cancelled" as const,
        cancelledAt: now.toISOString(),
        payments: [],
      };
      equal((await Promise.all([t.repo.apply(s, e, now), t.repo.apply(s, e, now)])).sort(), [
        "applied",
        "stale",
      ]);
      equal((await t.get(id)).subscription?.revision, 2);
      equal((await t.get(id)).operation.state, "succeeded");
      equal((await counts(sql, user)).events, 2);
    }),
);
databaseTest(
  "refund while query pending makes recovery snapshot stale",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      const p = t.evidence.payments[0];
      await callback(sql, p.notification, p.factsDigest);
      const s = await t.get();
      equal(
        await callback(sql, { ...p.notification, eventKey: "refund", kind: "refund_confirmed" }),
        "applied",
      );
      equal(await t.repo.apply(s, t.evidence, now), "stale");
      equal((await t.get()).subscription?.status, "refunded");
      equal((await counts(sql, user)).audits, 0);
    }),
);
databaseTest(
  "audit SQL failure rolls back subscription ledger and operation writes",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      await sql`create function private.test_recovery_failure() returns trigger language plpgsql as 'begin raise exception ''forced test rollback''; end;'`;
      await sql`create trigger test_recovery_failure before insert on private.billing_recovery_audit for each row execute function private.test_recovery_failure()`;
      try {
        equal(await t.repo.apply(await t.get(), t.evidence, now), "unavailable");
        equal((await t.get()).subscription, null);
        equal((await t.get()).operation.state, "unknown");
        equal(await counts(sql, user), { events: 0, audits: 0 });
      } finally {
        await sql`drop trigger test_recovery_failure on private.billing_recovery_audit`;
        await sql`drop function private.test_recovery_failure()`;
      }
    }),
);
databaseTest(
  "foreign account cannot snapshot or apply owned operation",
  (url) =>
    withAccount(url, async (sql, user) => {
      const t = await setup(sql, user);
      const foreign = crypto.randomUUID();
      equal(await t.repo.snapshot(foreign, t.operationID), null);
      equal(await t.repo.apply({ ...await t.get(), userID: foreign }, t.evidence, now), "stale");
      equal(await counts(sql, user), { events: 0, audits: 0 });
    }),
);
