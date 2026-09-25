import {
  deriveSubscriptionAccess,
  type SubscriptionEvent,
  type SubscriptionRow,
  transitionSubscription,
} from "./subscription.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

const owner = "11111111-1111-1111-1111-111111111111";
const paidFrom = "2026-10-01T00:00:00.000Z";
const paidThrough = "2026-11-01T00:00:00.000Z";

function subscription(overrides: Partial<SubscriptionRow> = {}): SubscriptionRow {
  return {
    user_id: owner,
    provider_order_id: "test-order-1",
    status: "active",
    paid_from: paidFrom,
    paid_through: paidThrough,
    cancel_confirmed_at: null,
    revision: 1,
    ...overrides,
  };
}

Deno.test("a missing or cross-account subscription never grants Pro", () => {
  const now = new Date("2026-10-15T00:00:00.000Z");
  const free = {
    plan: "free",
    status: "none",
    paidThrough: null,
    proAccessEndsAt: null,
    revision: 0,
  };

  assertEquals(deriveSubscriptionAccess(null, owner, now), free);
  assertEquals(
    deriveSubscriptionAccess(subscription(), "22222222-2222-2222-2222-222222222222", now),
    free,
  );
});

Deno.test("an active paid period grants Pro until but not including its end", () => {
  const pro = {
    plan: "pro",
    status: "active",
    paidThrough,
    proAccessEndsAt: paidThrough,
    revision: 1,
  };
  assertEquals(deriveSubscriptionAccess(subscription(), owner, new Date(paidFrom)), pro);
  assertEquals(
    deriveSubscriptionAccess(subscription(), owner, new Date("2026-10-31T23:59:59.999Z")),
    pro,
  );
  assertEquals(deriveSubscriptionAccess(subscription(), owner, new Date(paidThrough)), {
    ...pro,
    plan: "free",
  });
});

Deno.test("confirmed cancellation adds exactly 72 hours after the paid period", () => {
  const cancelled = subscription({
    status: "cancelled",
    cancel_confirmed_at: "2026-10-15T00:00:00.000Z",
  });
  const pro = {
    plan: "pro",
    status: "cancelled",
    paidThrough,
    proAccessEndsAt: "2026-11-04T00:00:00.000Z",
    revision: 1,
  };
  assertEquals(deriveSubscriptionAccess(cancelled, owner, new Date(paidThrough)), pro);
  assertEquals(
    deriveSubscriptionAccess(cancelled, owner, new Date("2026-11-03T23:59:59.999Z")),
    pro,
  );
  assertEquals(
    deriveSubscriptionAccess(cancelled, owner, new Date("2026-11-04T00:00:00.000Z")),
    { ...pro, plan: "free" },
  );
});

Deno.test("failed renewal keeps only prepaid access while refunds and revocations grant none", () => {
  const failed = subscription({ status: "payment_failed" });
  assertEquals(
    deriveSubscriptionAccess(failed, owner, new Date("2026-10-31T23:59:59.999Z")).plan,
    "pro",
  );
  assertEquals(deriveSubscriptionAccess(failed, owner, new Date(paidThrough)).plan, "free");
  for (const status of ["refunded", "revoked"] as const) {
    const result = deriveSubscriptionAccess(
      subscription({ status }),
      owner,
      new Date("2026-10-15T00:00:00.000Z"),
    );
    assertEquals(result.plan, "free");
    assertEquals(result.proAccessEndsAt, null);
  }
});

Deno.test("malformed periods cancellation and clock fail closed", () => {
  const now = new Date("2026-10-15T00:00:00.000Z");
  for (
    const row of [
      subscription({ paid_from: "invalid" }),
      subscription({ paid_through: paidFrom }),
      subscription({ status: "cancelled", cancel_confirmed_at: null }),
      subscription({ status: "active", cancel_confirmed_at: now.toISOString() }),
      subscription({ status: "cancelled", cancel_confirmed_at: "invalid" }),
      subscription({
        status: "cancelled",
        cancel_confirmed_at: "2026-10-15T00:00:00.000Z",
        paid_through: "+275760-09-12T00:00:00.000Z",
      }),
      subscription({ revision: 0 }),
    ]
  ) {
    assertEquals(deriveSubscriptionAccess(row, owner, now).plan, "free");
  }
  assertEquals(deriveSubscriptionAccess(subscription(), owner, new Date("invalid")).plan, "free");
});

function event(overrides: Partial<SubscriptionEvent> = {}): SubscriptionEvent {
  return {
    event_key: "payment-1",
    kind: "payment_succeeded",
    user_id: owner,
    provider_order_id: "test-order-1",
    occurred_at: paidFrom,
    paid_from: paidFrom,
    paid_through: paidThrough,
    ...overrides,
  };
}

Deno.test("a verified first payment creates one paid period and a duplicate changes nothing", () => {
  const first = transitionSubscription(null, event(), new Set());
  assertEquals(first, {
    result: "applied",
    row: subscription(),
  });
  assertEquals(transitionSubscription(subscription(), event(), new Set(["payment-1"])), {
    result: "duplicate",
    row: subscription(),
  });
});

Deno.test("a renewal extends one contiguous period and a failed renewal never does", () => {
  const renewed = transitionSubscription(
    subscription(),
    event({
      event_key: "payment-2",
      occurred_at: paidThrough,
      paid_from: paidThrough,
      paid_through: "2026-12-01T00:00:00.000Z",
    }),
    new Set(["payment-1"]),
  );
  assertEquals(renewed, {
    result: "applied",
    row: subscription({
      paid_through: "2026-12-01T00:00:00.000Z",
      revision: 2,
    }),
  });
  assertEquals(
    transitionSubscription(
      subscription(),
      event({ event_key: "failed-2", kind: "payment_failed" }),
      new Set(["payment-1"]),
    ),
    { result: "applied", row: subscription({ status: "payment_failed", revision: 2 }) },
  );
});

Deno.test("renewal compares instants rather than timestamp formatting", () => {
  const current = subscription({ paid_through: "2026-11-01T08:00:00+08:00" });
  const result = transitionSubscription(
    current,
    event({
      event_key: "payment-2",
      occurred_at: paidThrough,
      paid_from: paidThrough,
      paid_through: "2026-12-01T00:00:00.000Z",
    }),
    new Set(["payment-1"]),
  );
  assertEquals(result, {
    result: "applied",
    row: { ...current, paid_through: "2026-12-01T00:00:00.000Z", revision: 2 },
  });
});

Deno.test("payment after confirmed cancellation requires reconciliation instead of reactivation", () => {
  const cancelled = subscription({
    status: "cancelled",
    cancel_confirmed_at: "2026-10-15T00:00:00.000Z",
    revision: 2,
  });
  const renewal = event({
    event_key: "payment-2",
    occurred_at: paidThrough,
    paid_from: paidThrough,
    paid_through: "2026-12-01T00:00:00.000Z",
  });
  assertEquals(transitionSubscription(cancelled, renewal, new Set(["cancel-1"])), {
    result: "reconcile",
    row: cancelled,
  });
});

Deno.test("cancellation keeps paid time and refund immediately removes access", () => {
  const cancelled = transitionSubscription(
    subscription(),
    event({
      event_key: "cancel-1",
      kind: "cancellation_confirmed",
      occurred_at: "2026-10-15T00:00:00.000Z",
    }),
    new Set(["payment-1"]),
  );
  assertEquals(cancelled, {
    result: "applied",
    row: subscription({
      status: "cancelled",
      cancel_confirmed_at: "2026-10-15T00:00:00.000Z",
      revision: 2,
    }),
  });
  if (cancelled.result !== "applied") throw new Error("expected cancellation");
  const refunded = transitionSubscription(
    cancelled.row,
    event({
      event_key: "refund-1",
      kind: "refund_confirmed",
      occurred_at: "2026-10-16T00:00:00.000Z",
    }),
    new Set(["payment-1", "cancel-1"]),
  );
  assertEquals(refunded.result, "applied");
  if (refunded.result !== "applied") throw new Error("expected refund");
  assertEquals(
    deriveSubscriptionAccess(refunded.row, owner, new Date("2026-10-17T00:00:00.000Z")).plan,
    "free",
  );
});
