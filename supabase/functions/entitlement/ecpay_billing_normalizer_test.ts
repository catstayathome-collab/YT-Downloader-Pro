import { computeAioMac } from "./ecpay_aio_checksum.ts";
import { verifyAioNotification } from "./ecpay_aio_notification.ts";
import fixtures from "./test-fixtures/ecpay/notifications.json" with { type: "json" };
import {
  authorizationEventKey,
  type NormalizationResult,
  normalizeAioPayment,
  paymentFactsDigest,
  type TrustedOrderFacts,
} from "./ecpay_billing_normalizer.ts";

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
const config = { merchantID: "1234567", hashKey: "local-key", hashIV: "local-iv" };
const order: TrustedOrderFacts = {
  userID: "11111111-1111-4111-8111-111111111111",
  merchantID: "1234567",
  orderID: "LOCAL001",
  currency: "TWD",
  amountMinor: 8000,
};
const period = { from: "2026-09-28T04:00:00.000Z", through: "2026-10-28T04:00:00.000Z" };
async function candidate(extra: Record<string, string> = {}, route: "first" | "renewal" = "first") {
  const fields = { ...fixtures[route], ...extra };
  return await verifyAioNotification(
    new Request("https://local.invalid", {
      method: "POST",
      body: new URLSearchParams({ ...fields, CheckMacValue: await computeAioMac(fields, config) }),
    }),
    route,
    config,
  );
}
function payment(result: NormalizationResult) {
  if (result.kind !== "payment") throw new Error("Expected normalized payment");
  return result.value;
}

Deno.test("same authorization has same replay identity across routes", async () => {
  const first = payment(
    await normalizeAioPayment(await candidate(), order, () => Promise.resolve(period)),
  );
  const renewal = payment(
    await normalizeAioPayment(
      await candidate({ Gwsr: "123", ProcessDate: fixtures.first.process_date }, "renewal"),
      order,
      () => Promise.resolve(period),
    ),
  );
  equal(first, renewal);
  equal(first.notification.amountMinor, 8000);
  equal(first.notification.kind, "payment_succeeded");
  equal(first.notification.currency, "TWD");
  equal(/^aio-v1:[0-9a-f]{64}$/.test(first.notification.eventKey), true);
  equal(/^[0-9a-f]{64}$/.test(first.factsDigest), true);
  equal(Object.isFrozen(first.notification), true);
});
Deno.test("identity binds merchant order and authorization without tuple ambiguity", async () => {
  const key = await authorizationEventKey("1234567", "LOCAL001", "123");
  for (
    const tuple of [["7654321", "LOCAL001", "123"], ["1234567", "LOCAL002", "123"], [
      "1234567",
      "LOCAL001",
      "124",
    ]]
  ) equal(await authorizationEventKey(...tuple as [string, string, string]) === key, false);
  equal(
    await authorizationEventKey("1", "23", "4") === await authorizationEventKey("12", "3", "4"),
    false,
  );
});
Deno.test("simulation and failure never normalize into a paid event", async () => {
  for (const fields of [{ SimulatePaid: "1" }, { RtnCode: "101" }] as Record<string, string>[]) {
    let calls = 0;
    const result = await normalizeAioPayment(await candidate(fields), order, () => {
      calls++;
      return Promise.resolve(period);
    });
    equal(result.kind, "needs_review");
    equal(calls, 0);
  }
});
Deno.test("missing mismatched and invalid trusted orders fail before resolving a period", async () => {
  for (
    const facts of [
      null,
      { ...order, merchantID: "7654321" },
      { ...order, orderID: "OTHER" },
      { ...order, userID: "email@example.invalid" },
      { ...order, amountMinor: 8100 },
      { ...order, amountMinor: NaN },
      { ...order, amountMinor: 0 },
      { ...order, amountMinor: 8000.5 },
    ]
  ) {
    let calls = 0;
    equal(
      (await normalizeAioPayment(await candidate(), facts, () => {
        calls++;
        return Promise.resolve(period);
      })).kind,
      "needs_review",
    );
    equal(calls, 0);
  }
});
Deno.test("minor unit multiplication overflow requires review", async () => {
  const value = "9007199254740991";
  equal(
    (await normalizeAioPayment(await candidate({ amount: value, TradeAmt: value }), {
      ...order,
      amountMinor: Number.MAX_SAFE_INTEGER,
    }, () => Promise.resolve(period))).kind,
    "needs_review",
  );
});
Deno.test("callback identity period and counters cannot override trusted facts", async () => {
  const plain = payment(
    await normalizeAioPayment(await candidate(), order, () => Promise.resolve(period)),
  );
  const result = await normalizeAioPayment(
    await candidate({
      CustomField1: "other-user",
      userID: "other-user",
      paidFrom: "2099-01-01",
      TotalSuccessTimes: "999",
      TotalSuccessAmount: "999999",
      email: "private@example.invalid",
    }),
    order,
    (identity) => {
      equal(identity, {
        merchantID: order.merchantID,
        orderID: order.orderID,
        authorizationID: "123",
      });
      return Promise.resolve(period);
    },
  );
  equal(payment(result), plain);
  equal(
    Object.keys(plain.notification).sort(),
    [
      "amountMinor",
      "currency",
      "eventKey",
      "kind",
      "occurredAt",
      "orderID",
      "paidFrom",
      "paidThrough",
      "provider",
    ].sort(),
  );
});
Deno.test("explicit month end and leap year periods are preserved not inferred", async () => {
  for (
    const schedule of [
      { from: "2024-01-31T00:00:00.000Z", through: "2024-02-29T00:00:00.000Z" },
      { from: "2024-02-29T00:00:00.000Z", through: "2024-03-31T00:00:00.000Z" },
      { from: "2025-01-31T00:00:00.000Z", through: "2025-02-28T00:00:00.000Z" },
    ]
  ) {
    const result = payment(
      await normalizeAioPayment(await candidate(), order, () => Promise.resolve(schedule)),
    );
    equal(result.notification.paidFrom, schedule.from);
    equal(result.notification.paidThrough, schedule.through);
  }
});
Deno.test("missing invalid reversed or unavailable periods require review", async () => {
  const valid = await candidate();
  equal((await normalizeAioPayment(valid, order, null)).kind, "needs_review");
  for (
    const schedule of [
      null,
      { ...period, through: period.from },
      { from: period.through, through: period.from },
      { ...period, from: "2026-02-30T00:00:00Z" },
      { ...period, from: "2026-09-28T04:00:00" },
      { ...period, from: "2026/09/28 04:00:00" },
      { ...period, from: "2026-09-28T24:00:00Z" },
    ]
  ) {
    equal(
      (await normalizeAioPayment(valid, order, () => Promise.resolve(schedule))).kind,
      "needs_review",
    );
  }
  const result = await normalizeAioPayment(valid, order, () => {
    return Promise.reject(new Error("SECRET provider response"));
  });
  equal(result, { kind: "needs_review", reason: "period_unavailable" });
});
Deno.test("facts digest canonicalizes instants and detects conflicting facts", async () => {
  const { notification, factsDigest } = payment(
    await normalizeAioPayment(await candidate(), order, () => Promise.resolve(period)),
  );
  equal(
    await paymentFactsDigest({
      ...notification,
      occurredAt: "2026-09-28T12:00:00+08:00",
      paidFrom: "2026-09-28T12:00:00+08:00",
      paidThrough: "2026-10-28T12:00:00+08:00",
    }),
    factsDigest,
  );
  for (
    const change of [
      { amountMinor: 8100 },
      { paidFrom: "2026-09-27T04:00:00Z" },
      { paidThrough: "2026-11-28T04:00:00Z" },
      { occurredAt: "2026-09-28T04:00:01Z" },
      { orderID: "LOCAL002" },
      { eventKey: await authorizationEventKey("1234567", "LOCAL001", "124") },
    ]
  ) equal(await paymentFactsDigest({ ...notification, ...change }) === factsDigest, false);
});

Deno.test("order identity cannot change across asynchronous period lookup", async () => {
  const mutableOrder = { ...order };
  const result = payment(
    await normalizeAioPayment(await candidate(), mutableOrder, () => {
      mutableOrder.orderID = "OTHER";
      return Promise.resolve(period);
    }),
  );
  equal(result.notification.orderID, order.orderID);
});
