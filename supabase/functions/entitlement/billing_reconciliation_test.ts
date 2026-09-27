import fixture from "./test-fixtures/ecpay/queries.json" with { type: "json" };
import {
  decideRecovery,
  type RecoverySnapshot,
  validateMockQuery,
} from "./billing_reconciliation.ts";
import type { PeriodResolver, TrustedOrderFacts } from "./ecpay_billing_normalizer.ts";

function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}
const order: TrustedOrderFacts = {
  userID: "11111111-1111-4111-8111-111111111111",
  merchantID: "1234567",
  orderID: "LOCAL001",
  currency: "TWD",
  amountMinor: 8000,
};
const resolve: PeriodResolver = ({ authorizationID }) =>
  Promise.resolve(
    authorizationID === "123"
      ? { from: "2026-09-28T04:00:00Z", through: "2026-10-28T04:00:00Z" }
      : authorizationID === "124"
      ? { from: "2026-10-28T04:00:00Z", through: "2026-11-28T04:00:00Z" }
      : null,
  );
const snapshot: RecoverySnapshot = {
  userID: order.userID,
  operation: {
    id: "operation",
    requestID: "request",
    orderID: order.orderID,
    kind: "checkout",
    state: "unknown",
  },
  subscription: null,
  stateToken: "test-state",
};
const bytes = (value: unknown) => new TextEncoder().encode(JSON.stringify(value));
const query = (value: unknown = fixture, resolver = resolve) =>
  validateMockQuery(bytes(value), order, resolver);
const row = {
  user_id: order.userID,
  provider_order_id: order.orderID,
  status: "active" as const,
  paid_from: "2026-09-28T04:00:00.000Z",
  paid_through: "2026-10-28T04:00:00.000Z",
  cancel_confirmed_at: null,
  revision: 1,
};

Deno.test("mock evidence normalizes sorts deduplicates and removes private data", async () => {
  const evidence = await query({
    ...fixture,
    card4no: "1234",
    authorizations: [...fixture.authorizations, {
      ...fixture.authorizations[0],
      auth_code: "SECRET",
    }],
  });
  if (evidence.kind !== "order") throw new Error("Expected order");
  equal(evidence.payments.length, 2);
  equal(evidence.payments[0].notification.paidFrom, row.paid_from);
  equal(JSON.stringify(evidence).includes("SECRET"), false);
  equal(decideRecovery(snapshot, evidence).kind, "payments");
});
Deno.test("strict JSON rejects duplicate escaped nested and case collision keys", async () => {
  for (
    const raw of [
      '{"kind":"not_found","kind":"unavailable"}',
      '{"kind":"not_found","k\\u0069nd":"unavailable"}',
      '{"kind":"not_found","Kind":"unavailable"}',
      '{"kind":"not_found","nested":{"a":1,"a":2}}',
      "[",
      "null",
      "[]",
      " ".repeat(65537),
      "[".repeat(40) + "0" + "]".repeat(40),
    ]
  ) {
    equal(
      (await validateMockQuery(new TextEncoder().encode(raw), order, resolve)).kind,
      "unavailable",
    );
  }
  equal((await validateMockQuery(new Uint8Array([255]), order, resolve)).kind, "unavailable");
});
Deno.test("query rejects wrong identities aliases malformed facts simulation and conflicting authorizations", async () => {
  for (
    const data of [
      { ...fixture, mode: "live" },
      { ...fixture, merchantID: "wrong" },
      { ...fixture, orderID: "other" },
      { ...fixture, MerchantID: "1234567" },
      { ...fixture, authorizations: Array(121).fill(fixture.authorizations[0]) },
      ...[
        { amountTWD: "81" },
        { amountTWD: "8e1" },
        { amountTWD: "80.0" },
        { amountTWD: "9007199254740991" },
        { authorizationID: "" },
        { occurredAt: "2026-02-30T00:00:00Z" },
        { simulated: true },
        { outcome: "failed" },
        { Amount: "80" },
      ].map((change) => ({
        ...fixture,
        authorizations: [{ ...fixture.authorizations[0], ...change }],
      })),
      {
        ...fixture,
        authorizations: [fixture.authorizations[0], {
          ...fixture.authorizations[0],
          occurredAt: "2026-10-28T04:00:01Z",
        }],
      },
    ]
  ) equal((await query(data)).kind, "unavailable");
});
Deno.test("missing period and incomplete histories cannot propose payment", async () => {
  equal((await query(fixture, () => Promise.resolve(null))).kind, "unavailable");
  equal((await query(fixture, () => Promise.reject(new Error("SECRET")))).kind, "unavailable");
  const evidence = await query({ ...fixture, complete: false });
  equal(decideRecovery(snapshot, evidence), { kind: "needs_review", reason: "incomplete_history" });
});
Deno.test("unavailable not found and unpaid checkout decisions stay nonfinancial", async () => {
  for (const kind of ["unavailable", "not_found"] as const) {
    equal(decideRecovery(snapshot, await query({ mode: "mock", kind })), {
      kind: "needs_review",
      reason: kind,
    });
  }
  equal(decideRecovery(snapshot, await query({ ...fixture, authorizations: [] })), {
    kind: "checkout_confirmed",
  });
});
Deno.test("gaps and overlaps cannot partially replay a batch", async () => {
  for (const from of ["2026-10-29T04:00:00Z", "2026-10-27T04:00:00Z"]) {
    const evidence = await query(
      fixture,
      (identity) =>
        identity.authorizationID === "123"
          ? resolve(identity)
          : Promise.resolve({ from, through: "2026-11-28T04:00:00Z" }),
    );
    equal(decideRecovery(snapshot, evidence).kind, "needs_review");
  }
  const evidence = await query(
    { ...fixture, authorizations: [fixture.authorizations[0]] },
    () => Promise.resolve({ from: "2026-10-29T04:00:00Z", through: "2026-11-28T04:00:00Z" }),
  );
  equal(decideRecovery({ ...snapshot, subscription: row }, evidence).kind, "needs_review");
});
Deno.test("terminal subscriptions and cross account snapshots cannot reactivate", async () => {
  const evidence = await query();
  for (const status of ["cancelled", "refunded", "revoked"] as const) {
    equal(
      decideRecovery({ ...snapshot, subscription: { ...row, status } }, evidence).kind,
      "needs_review",
    );
  }
  equal(
    decideRecovery({ ...snapshot, subscription: { ...row, user_id: "other" } }, evidence).kind,
    "needs_review",
  );
  equal(
    decideRecovery(
      { ...snapshot, operation: { ...snapshot.operation, orderID: "other" } },
      evidence,
    ).kind,
    "needs_review",
  );
});
Deno.test("cancel needs confirmed time and active cancellation never resends", async () => {
  const cancel = {
    ...snapshot,
    subscription: row,
    operation: { ...snapshot.operation, kind: "cancel" as const },
  };
  equal(decideRecovery(cancel, await query({ ...fixture, authorizations: [] })), {
    kind: "needs_review",
    reason: "still_active",
  });
  for (const cancelledAt of [null, "2026-11-29T00:00:00Z", "2026-02-30T00:00:00Z"]) {
    equal(
      decideRecovery(
        cancel,
        await query({ ...fixture, execution: "cancelled", cancelledAt, authorizations: [] }),
      ).kind,
      "needs_review",
    );
  }
  equal(
    decideRecovery(
      cancel,
      await query({
        ...fixture,
        execution: "cancelled",
        cancelledAt: "2026-10-27T04:00:00Z",
        authorizations: [],
      }),
    ),
    { kind: "cancellation", occurredAt: "2026-10-27T04:00:00.000Z" },
  );
});
Deno.test("missing renewal is offered before cancellation with fresh snapshot followup", async () => {
  const cancel = {
    ...snapshot,
    subscription: row,
    operation: { ...snapshot.operation, kind: "cancel" as const },
  };
  const data = {
    ...fixture,
    execution: "cancelled",
    cancelledAt: "2026-11-27T04:00:00Z",
    authorizations: [fixture.authorizations[0]],
  };
  equal(decideRecovery(cancel, await query(data)).kind, "payments");
  equal(
    decideRecovery({
      ...cancel,
      subscription: { ...row, paid_through: "2026-11-28T04:00:00Z", revision: 2 },
    }, await query({ ...data, authorizations: [] })).kind,
    "cancellation",
  );
});

Deno.test("duplicate detection is enforced even when last-key-wins would yield valid facts", async () => {
  const raw = JSON.stringify(fixture);
  for (
    const changed of [
      raw.replace('"merchantID":"1234567"', '"merchantID":"wrong","merchantID":"1234567"'),
      raw.replace('"merchantID":"1234567"', '"merchant\\u0049D":"wrong","merchantID":"1234567"'),
      raw.replace('"amountTWD":"80"', '"amountTWD":"81","amountTWD":"80"'),
    ]
  ) {
    equal(
      (await validateMockQuery(new TextEncoder().encode(changed), order, resolve)).kind,
      "unavailable",
    );
  }
});
Deno.test("bounds accept 120 authorizations and exactly 65536 bytes", async () => {
  equal(
    (await query({ ...fixture, authorizations: Array(120).fill(fixture.authorizations[0]) })).kind,
    "order",
  );
  const raw = JSON.stringify(fixture).padEnd(65536, " ");
  equal((await validateMockQuery(new TextEncoder().encode(raw), order, resolve)).kind, "order");
  equal(
    (await validateMockQuery(new TextEncoder().encode(raw + " "), order, resolve)).kind,
    "unavailable",
  );
});
Deno.test("trusted order snapshot cannot mutate during period lookup", async () => {
  const mutable = { ...order };
  const evidence = await validateMockQuery(bytes(fixture), mutable, (identity) => {
    mutable.orderID = "OTHER";
    return resolve(identity);
  });
  if (evidence.kind !== "order") throw new Error("Expected stable evidence");
  equal(evidence.orderID, order.orderID);
  equal(evidence.payments.every((p) => p.notification.orderID === order.orderID), true);
});
