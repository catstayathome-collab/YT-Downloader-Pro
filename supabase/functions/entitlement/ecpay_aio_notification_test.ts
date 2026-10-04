import { computeAioMac } from "./ecpay_aio_checksum.ts";
import { InvalidAioNotification, verifyAioNotification } from "./ecpay_aio_notification.ts";
import fixtures from "./test-fixtures/ecpay/notifications.json" with { type: "json" };

const config = { merchantID: "1234567", hashKey: "local-key", hashIV: "local-iv" };
const { first, renewal } = fixtures;
function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error("Assertion failed");
}
async function body(fields: Record<string, string>) {
  return new URLSearchParams({ ...fields, CheckMacValue: await computeAioMac(fields, config) })
    .toString();
}
function request(raw: string, contentType = "application/x-www-form-urlencoded") {
  return new Request("https://local.invalid", {
    method: "POST",
    headers: { "Content-Type": contentType },
    body: raw,
  });
}
async function rejects(request: Request, route: "first" | "renewal" = "first", reason?: string) {
  try {
    await verifyAioNotification(request, route, config);
  } catch (error) {
    if (!(error instanceof InvalidAioNotification)) throw error;
    if (reason) equal(error.reason, reason);
    return;
  }
  throw new Error("Expected rejection");
}
Deno.test("route mappings return only bounded payment facts", async () => {
  for (
    const [route, fields, id, time] of [["first", first, "123", "2026-09-28T04:00:00.000Z"], [
      "renewal",
      renewal,
      "124",
      "2026-10-28T04:00:00.000Z",
    ]] as const
  ) {
    const candidate = await verifyAioNotification(
      request(
        await body({
          ...fields,
          auth_code: "SECRET",
          card4no: "1234",
          CustomField1: "email@example.invalid",
        }),
      ),
      route,
      config,
    );
    equal(JSON.parse(JSON.stringify(candidate)), {
      merchantID: "1234567",
      orderID: "LOCAL001",
      authorizationID: id,
      occurredAt: time,
      amountTWD: "80",
      outcome: "paid",
      simulated: false,
    });
    equal(Object.isFrozen(candidate), true);
  }
});
Deno.test("wrong and missing merchant reject even with valid MAC", async () => {
  for (const merchant of ["7654321", "", "1234567 "]) {
    await rejects(request(await body({ ...first, MerchantID: merchant })), "first", "merchant");
  }
});
Deno.test("unknown fields are signed, never retained", async () => {
  const raw = await body({ ...first, Extra: "one" });
  await verifyAioNotification(request(raw), "first", config);
  await rejects(request(raw.replace("Extra=one", "Extra=two")), "first", "mac");
  await rejects(request(raw.replace(/CheckMacValue=.*/, "CheckMacValue=bad")), "first", "mac");
});
Deno.test("strict decoding rejects duplicates, case collisions, malformed encoding", async () => {
  const raw = await body(first);
  for (
    const extra of [
      "Merchant%49D=1234567",
      "merchantid=1234567",
      "x=%FF",
      "x=%ZZ",
      "x=%",
      "=empty",
      "missingequals",
    ]
  ) await rejects(request(raw + "&" + extra));
  await rejects(
    request(await body({ ...first, MerchantID: "%31%32%33%34%35%36%37" })),
    "first",
    "merchant",
  );
  await rejects(
    new Request("https://local.invalid", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new Uint8Array([255]),
    }),
  );
});
Deno.test("method and content type reject", async () => {
  await rejects(new Request("https://local.invalid"), "first", "method");
  await rejects(request(await body(first), "application/json"), "first", "content_type");
});
Deno.test("numeric, calendar, missing identity and conflicting aliases reject", async () => {
  for (const value of ["1e2", "-1", "+1", "1.5", "9007199254740992", "", "01"]) {
    await rejects(request(await body({ ...first, amount: value, TradeAmt: value })));
    await rejects(request(await body({ ...renewal, Gwsr: value })), "renewal");
  }
  for (
    const date of [
      "2026/02/29 12:00:00",
      "2026/09/31 12:00:00",
      "2026/09/28 24:00:00",
      "2026/13/28 12:00:00",
      "2026-09-28T12:00:00Z",
    ]
  ) await rejects(request(await body({ ...first, process_date: date })));
  await rejects(request(await body({ ...first, TradeAmt: "81" })));
  await rejects(request(await body({ ...first, gwsr: "" })));
  await rejects(request(await body({ ...renewal, process_date: first.process_date })), "renewal");
  await rejects(request(await body({ ...first, PaymentType: "ATM" })));
  const leap = await verifyAioNotification(
    request(await body({ ...first, process_date: "2024/02/29 00:00:00" })),
    "first",
    config,
  );
  equal(leap.occurredAt, "2024-02-28T16:00:00.000Z");
});
Deno.test("simulation is explicit and invalid flags reject", async () => {
  for (const route of ["first", "renewal"] as const) {
    const fields = route === "first" ? first : renewal;
    const candidate = await verifyAioNotification(
      request(await body({ ...fields, SimulatePaid: "1" })),
      route,
      config,
    );
    equal(candidate.simulated, true);
    await rejects(request(await body({ ...fields, SimulatePaid: "2" })), route);
    const failed = await verifyAioNotification(
      request(await body({ ...fields, RtnCode: "101" })),
      route,
      config,
    );
    equal(failed.outcome, "failed");
  }
  const fields: Record<string, string> = { ...first };
  delete fields.SimulatePaid;
  await rejects(request(await body(fields)));
});
Deno.test("field count and decoded byte boundaries", async () => {
  const fields: Record<string, string> = { ...first };
  while (Object.keys(fields).length < 127) fields[`x${Object.keys(fields).length}`] = "";
  await verifyAioNotification(request(await body(fields)), "first", config);
  await rejects(request(await body({ ...fields, overflow: "" })), "first", "limits");
  await verifyAioNotification(
    request(await body({ ...first, ["n".repeat(64)]: "v".repeat(8192) })),
    "first",
    config,
  );
  for (
    const extra of [{ ["n".repeat(65)]: "" }, { extra: "v".repeat(8193) }, {
      extra: "字".repeat(2731),
    }] as Record<string, string>[]
  ) await rejects(request(await body({ ...first, ...extra })), "first", "limits");
});
Deno.test("oversized streaming input is cancelled", async () => {
  let cancelled = false;
  const stream = new ReadableStream({
    pull(controller) {
      controller.enqueue(new Uint8Array(32769));
    },
    cancel() {
      cancelled = true;
    },
  });
  await rejects(
    new Request("https://local.invalid", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: stream,
    }),
    "first",
    "limits",
  );
  equal(cancelled, true);
});
