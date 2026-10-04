import { createBillingAPI } from "./billing_api.ts";

const userID = "10000000-0000-0000-0000-000000000001";
const requestID = "20000000-0000-0000-0000-000000000001";
function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error("unexpected result");
}
function fixture() {
  const calls: unknown[] = [];
  const handler = createBillingAPI({
    verifyAccessToken: (token) => {
      if (token !== "valid") throw new Error("secret provider failure");
      return Promise.resolve(userID);
    },
    execute: (subject, command) => {
      calls.push({ subject, command });
      return Promise.resolve({ status: 200, body: { mode: "mock" } });
    },
  });
  return { handler, calls };
}
function request(path: string, body: unknown, token = "valid") {
  return new Request(`http://localhost/billing/${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
}

Deno.test("billing routes bind valid commands only to the verified account", async () => {
  const { handler, calls } = fixture();
  for (
    const [path, body] of [
      ["status", { schema: 1 }],
      ["checkout", { schema: 1, requestID }],
      ["cancel", { schema: 1, requestID, orderID: "test-order" }],
    ] as const
  ) {
    const response = await handler(request(path, body));
    equal(response.status, 200);
    equal(response.headers.get("Cache-Control"), "no-store");
  }
  equal(calls, [
    { subject: userID, command: { kind: "status" } },
    { subject: userID, command: { kind: "checkout", requestID } },
    { subject: userID, command: { kind: "cancel", requestID, orderID: "test-order" } },
  ]);
});

Deno.test("billing rejects client-selected authority price and malformed commands", async () => {
  const { handler, calls } = fixture();
  for (
    const body of [
      { schema: 1, requestID, userID },
      { schema: 1, requestID, amountMinor: 1 },
      { schema: 1, requestID, plan: "pro" },
      { schema: 2, requestID },
      { schema: 1, requestID: "not-a-uuid" },
      [],
      null,
    ]
  ) equal((await handler(request("checkout", body))).status, 400);
  equal((await handler(request("cancel", { schema: 1, requestID, orderID: "" }))).status, 400);
  equal((await handler(request("status", { schema: 1, orderID: "other" }))).status, 400);
  equal(calls.length, 0);
});

Deno.test("billing authentication failure never executes a command or exposes details", async () => {
  const { handler, calls } = fixture();
  const response = await handler(request("checkout", { schema: 1, requestID }, "invalid"));
  equal(response.status, 401);
  equal(await response.json(), { code: "unauthorized" });
  equal(calls.length, 0);
  const invalidIdentity = createBillingAPI({
    verifyAccessToken: () => Promise.resolve("not-a-user-uuid"),
    execute: () => {
      throw new Error("must not execute");
    },
  });
  equal((await invalidIdentity(request("status", { schema: 1 }))).status, 401);
});

Deno.test("billing rejects wrong routes methods and oversized streamed bodies", async () => {
  const { handler, calls } = fixture();
  equal((await handler(new Request("http://localhost/billing/status"))).status, 405);
  equal((await handler(request("unknown", { schema: 1 }))).status, 404);
  equal((await handler(request("status?user=other", { schema: 1 }))).status, 400);
  const wrongType = request("status", { schema: 1 });
  wrongType.headers.set("Content-Type", "text/plain");
  equal((await handler(wrongType)).status, 400);
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      controller.enqueue(new Uint8Array(1025));
    },
    cancel() {
      cancelled = true;
    },
  });
  const response = await handler(
    new Request("http://localhost/billing/status", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer valid" },
      body: stream,
    }),
  );
  equal(response.status, 400);
  equal(cancelled, true);
  equal(calls.length, 0);
});

Deno.test("billing internal errors are bounded and never echo tokens or SQL", async () => {
  const handler = createBillingAPI({
    verifyAccessToken: () => Promise.resolve(userID),
    execute: () => {
      throw new Error("private SQL and credential details");
    },
  });
  const response = await handler(request("status", { schema: 1 }));
  equal(response.status, 503);
  equal(await response.json(), { code: "service_unavailable" });
});
