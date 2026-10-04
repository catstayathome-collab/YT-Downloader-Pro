import postgres from "postgres";
import { createBillingAPI } from "./billing_api.ts";
import { type BillingProvider, createBillingManagement } from "./billing_management.ts";
import { createMockBillingProvider } from "./mock_billing_provider.ts";
import { createPostgresBillingManagementRepository } from "./postgres_billing_management_repository.ts";
import { createPostgresBillingRepository } from "./postgres_billing_repository.ts";
import { processBillingNotification } from "./billing_event_processor.ts";
import { databaseTest, withAccount } from "./test-fixtures/local_database.ts";

databaseTest("failed operation insertion rolls back its new order", async (url) => {
  await withAccount(url, async (sql, userID) => {
    const repository = createPostgresBillingManagementRepository(sql);
    let code: unknown;
    try {
      await repository.prepare(userID, { kind: "checkout", requestID: crypto.randomUUID() }, {
        operationID: "invalid-uuid",
        orderID: "rollback-order",
      }, new Date("2026-10-15"));
    } catch (error) {
      code = (error as { code: string }).code;
    }
    equal(code, "22P02");
    equal((await sql`select * from private.billing_orders where user_id = ${userID}`).length, 0);
    equal((await repository.snapshot(userID)).operations, []);
  });
});

databaseTest(
  "failed cancellation commit rolls back access and replay after restart never calls provider",
  async (url) => {
    await withAccount(url, async (sql, userID) => {
      let calls = 0;
      const provider: BillingProvider = {
        ...createMockBillingProvider(),
        async cancelSubscription(command) {
          calls++;
          // Simulate an event identity collision after the external confirmation.
          await sql`insert into private.subscription_events
          (subscription_id, provider, provider_event_key, event_kind, occurred_at)
          select subscription_id, 'ecpay', ${`management-${command.operationID}`},
            'payment_succeeded', '2026-10-01' from private.subscriptions
          where provider_order_id = ${command.orderID}`;
          return "confirmed";
        },
      };
      const api = app(sql, userID, provider);
      const orderID =
        (await api.call("checkout", { requestID: crypto.randomUUID() })).body.operation.orderID;
      await pay(sql, orderID);
      const requestID = crypto.randomUUID();
      equal(await api.call("cancel", { requestID, orderID }), {
        status: 503,
        body: { code: "service_unavailable" },
      });
      const restarted = app(sql, userID, provider);
      const replay = await restarted.call("cancel", { requestID, orderID });
      equal(replay.status, 202);
      equal(replay.body.operation.state, "pending");
      equal(calls, 1);
      equal(
        (await restarted.call("cancel", { requestID: crypto.randomUUID(), orderID })).status,
        409,
      );
      const access = (await restarted.call("status")).body.access;
      equal(access.status, "active");
      equal(access.revision, 1);
      equal(access.proAccessEndsAt, "2026-11-01T00:00:00.000Z");
    });
  },
);

databaseTest(
  "late confirmation requires reconciliation and already cancelled orders stay idempotent",
  async (url) => {
    await withAccount(url, async (sql, userID) => {
      const api = app(sql, userID);
      const orderID =
        (await api.call("checkout", { requestID: crypto.randomUUID() })).body.operation.orderID;
      await pay(sql, orderID);
      api.setTime("2026-11-02T00:00:00Z");
      const late = await api.call("cancel", { requestID: crypto.randomUUID(), orderID });
      equal(late.status, 202);
      equal(late.body.operation.state, "unknown");
      equal((await api.call("status")).body.access.plan, "free");
      equal((await api.call("status")).body.access.revision, 1);
    });
    await withAccount(url, async (sql, userID) => {
      const api = app(sql, userID);
      const orderID =
        (await api.call("checkout", { requestID: crypto.randomUUID() })).body.operation.orderID;
      await pay(sql, orderID);
      await api.call("cancel", { requestID: crypto.randomUUID(), orderID });
      equal((await api.call("cancel", { requestID: crypto.randomUUID(), orderID })).status, 200);
      equal((await api.call("status")).body.access.revision, 2);
    });
  },
);

databaseTest("different simultaneous checkout keys still create only one order", async (url) => {
  await withAccount(url, async (sql, userID) => {
    let calls = 0;
    const mock = createMockBillingProvider();
    const api = app(sql, userID, {
      ...mock,
      createCheckout(command, signal) {
        calls++;
        return mock.createCheckout(command, signal);
      },
    });
    const results = await Promise.all([
      api.call("checkout", { requestID: crypto.randomUUID() }),
      api.call("checkout", { requestID: crypto.randomUUID() }),
    ]);
    equal(results.map((value) => value.status).sort(), [200, 409]);
    equal(calls, 1);
    equal((await sql`select * from private.billing_orders where user_id = ${userID}`).length, 1);
  });
});

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

function app(sql: postgres.Sql, userID: string, provider = createMockBillingProvider()) {
  let instant = new Date("2026-10-15T00:00:00.000Z");
  const execute = createBillingManagement({
    repository: createPostgresBillingManagementRepository(sql),
    provider,
    now: () => instant,
    randomUUID: () => crypto.randomUUID(),
    providerTimeoutMs: 50,
  });
  const handler = createBillingAPI({
    verifyAccessToken: (token) => {
      if (token !== "local-fixture") throw new Error("unauthorized");
      return Promise.resolve(userID);
    },
    execute,
  });
  return {
    setTime: (value: string) => {
      instant = new Date(value);
    },
    async call(path: string, values: Record<string, unknown> = {}) {
      const response = await handler(
        new Request(`http://localhost/billing/${path}`, {
          method: "POST",
          headers: { Authorization: "Bearer local-fixture", "Content-Type": "application/json" },
          body: JSON.stringify({ schema: 1, ...values }),
        }),
      );
      return { status: response.status, body: await response.json() };
    },
  };
}

async function pay(sql: postgres.Sql, orderID: string) {
  const result = await processBillingNotification(new Uint8Array([1]), new Headers(), {
    repository: createPostgresBillingRepository(sql),
    verifier: {
      verify: () =>
        Promise.resolve({
          provider: "ecpay" as const,
          orderID,
          eventKey: `pay-${orderID}`,
          kind: "payment_succeeded" as const,
          occurredAt: "2026-10-01T00:00:00Z",
          paidFrom: "2026-10-01T00:00:00Z",
          paidThrough: "2026-11-01T00:00:00Z",
          currency: "TWD",
          amountMinor: 8000,
        }),
    },
  });
  equal(result, "applied");
}

databaseTest(
  "checkout stores server price and replay does not grant Pro or create another order",
  async (url) => {
    await withAccount(url, async (sql, userID) => {
      let calls = 0;
      const mock = createMockBillingProvider();
      const api = app(sql, userID, {
        ...mock,
        createCheckout(command, signal) {
          calls++;
          equal(command.amountMinor, 8000);
          equal(command.currency, "TWD");
          return mock.createCheckout(command, signal);
        },
      });
      const requestID = crypto.randomUUID();
      const first = await api.call("checkout", { requestID });
      equal(first.status, 200);
      equal(first.body.operation.state, "succeeded");
      equal(first.body.mode, "mock");
      equal(await api.call("checkout", { requestID }), first);
      equal(calls, 1);
      equal((await sql`select * from private.billing_orders where user_id = ${userID}`).length, 1);
      const status = await api.call("status");
      equal(status.body.access.plan, "free");
      equal((await api.call("checkout", { requestID: crypto.randomUUID() })).status, 409);
      equal(
        (await api.call("cancel", { requestID, orderID: first.body.operation.orderID })).status,
        409,
      );
    });
  },
);

databaseTest(
  "confirmed cancellation preserves paid time plus exactly 72 hours and is idempotent",
  async (url) => {
    await withAccount(url, async (sql, userID) => {
      let calls = 0;
      const mock = createMockBillingProvider();
      const api = app(sql, userID, {
        ...mock,
        cancelSubscription(command, signal) {
          calls++;
          return mock.cancelSubscription(command, signal);
        },
      });
      const checkout = await api.call("checkout", { requestID: crypto.randomUUID() });
      const orderID = checkout.body.operation.orderID;
      await pay(sql, orderID);
      equal((await api.call("status")).body.access.plan, "pro");
      const requestID = crypto.randomUUID();
      const cancelled = await api.call("cancel", { requestID, orderID });
      equal(cancelled.status, 200);
      equal(cancelled.body.operation.state, "succeeded");
      equal(await api.call("cancel", { requestID, orderID }), cancelled);
      equal(calls, 1);
      const status = await api.call("status");
      equal(status.body.access.status, "cancelled");
      equal(status.body.access.proAccessEndsAt, "2026-11-04T00:00:00.000Z");
      equal(status.body.access.revision, 2);
      api.setTime("2026-11-03T23:59:59.999Z");
      equal((await api.call("status")).body.access.plan, "pro");
      api.setTime("2026-11-04T00:00:00.000Z");
      equal((await api.call("status")).body.access.plan, "free");
    });
  },
);

databaseTest(
  "unconfirmed or timed out cancellation preserves access and durable uncertainty",
  async (url) => {
    for (const outcome of ["pending", "throw", "timeout"] as const) {
      await withAccount(url, async (sql, userID) => {
        let calls = 0;
        const provider: BillingProvider = {
          ...createMockBillingProvider(),
          cancelSubscription(_command, signal) {
            calls++;
            if (outcome === "throw") throw new Error("provider secret");
            if (outcome === "pending") return Promise.resolve("pending");
            return new Promise((_resolve, reject) => {
              signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
            });
          },
        };
        const api = app(sql, userID, provider);
        const orderID =
          (await api.call("checkout", { requestID: crypto.randomUUID() })).body.operation.orderID;
        await pay(sql, orderID);
        const requestID = crypto.randomUUID();
        const result = await api.call("cancel", { requestID, orderID });
        equal(result.status, 202);
        equal(result.body.operation.state, outcome === "pending" ? "pending" : "unknown");
        equal(await api.call("cancel", { requestID, orderID }), result);
        equal(calls, 1);
        const access = (await api.call("status")).body.access;
        equal(access.status, "active");
        equal(access.revision, 1);
        equal(access.proAccessEndsAt, "2026-11-01T00:00:00.000Z");
      });
    }
  },
);

databaseTest("another account cannot read or cancel an owned order", async (url) => {
  await withAccount(url, async (sql, userID) => {
    const owner = app(sql, userID);
    const orderID =
      (await owner.call("checkout", { requestID: crypto.randomUUID() })).body.operation.orderID;
    await pay(sql, orderID);
    await withAccount(url, async (otherSQL, otherUserID) => {
      const other = app(otherSQL, otherUserID);
      const status = await other.call("status");
      equal(status.body.access.plan, "free");
      equal(status.body.operations, []);
      const requestID = crypto.randomUUID();
      const forbidden = await other.call("cancel", { requestID, orderID });
      equal(forbidden.status, 404);
      equal(await other.call("cancel", { requestID, orderID: "missing-order" }), forbidden);
      equal((await owner.call("status")).body.access.status, "active");
    });
  });
});

databaseTest(
  "independent API connections serialize checkout and cancel request replays",
  async (url) => {
    await withAccount(url, async (sql, userID) => {
      const second = postgres(url, { prepare: false, max: 2 });
      let checkoutCalls = 0;
      let cancelCalls = 0;
      const mock = createMockBillingProvider();
      const provider: BillingProvider = {
        ...mock,
        createCheckout(command, signal) {
          checkoutCalls++;
          return mock.createCheckout(command, signal);
        },
        cancelSubscription(command, signal) {
          cancelCalls++;
          return mock.cancelSubscription(command, signal);
        },
      };
      try {
        const firstAPI = app(sql, userID, provider);
        const secondAPI = app(second, userID, provider);
        const requestID = crypto.randomUUID();
        const results = await Promise.all([
          firstAPI.call("checkout", { requestID }),
          secondAPI.call("checkout", { requestID }),
        ]);
        equal(results.every((result) => [200, 202].includes(result.status)), true);
        equal(checkoutCalls, 1);
        equal(results[0].body.operation.orderID, results[1].body.operation.orderID);
        const orderID = results[0].body.operation.orderID;
        await pay(sql, orderID);
        const cancellationID = crypto.randomUUID();
        await Promise.all([
          firstAPI.call("cancel", { requestID: cancellationID, orderID }),
          secondAPI.call("cancel", { requestID: cancellationID, orderID }),
        ]);
        equal(cancelCalls, 1);
        equal((await firstAPI.call("status")).body.access.revision, 2);
      } finally {
        await second.end();
      }
    });
  },
);
