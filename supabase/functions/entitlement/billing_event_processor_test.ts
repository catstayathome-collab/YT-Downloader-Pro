import {
  type BillingEventRepository,
  type BillingEventTransaction,
  processBillingNotification,
  type VerifiedBillingNotification,
} from "./billing_event_processor.ts";
import type { SubscriptionRow } from "./subscription.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

const userID = "11111111-1111-1111-1111-111111111111";
const orderID = "order-1";
const firstPayment: VerifiedBillingNotification = {
  provider: "ecpay",
  eventKey: "charge-1",
  kind: "payment_succeeded",
  orderID,
  occurredAt: "2026-10-01T00:00:00.000Z",
  paidFrom: "2026-10-01T00:00:00.000Z",
  paidThrough: "2026-11-01T00:00:00.000Z",
  currency: "TWD",
  amountMinor: 8_000,
};

class MemoryRepository implements BillingEventRepository {
  orders = new Map([[orderID, { userID, currency: "TWD", amountMinor: 8_000 }]]);
  rows = new Map<string, SubscriptionRow>();
  events = new Map<string, string>();
  recordedEvents: Array<
    { subscriptionID: string; kind: string; userID: string; occurredAt: string }
  > = [];
  transactions = 0;
  failOnEventInsert = false;
  conflictOnEventInsert = false;
  private tail: Promise<void> = Promise.resolve();

  async transaction<T>(work: (tx: BillingEventTransaction) => Promise<T>): Promise<T> {
    const previous = this.tail;
    let release = () => {};
    this.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    this.transactions += 1;
    const rows = new Map(this.rows);
    const events = new Map(this.events);
    const recordedEvents = [...this.recordedEvents];
    try {
      const result = await work({
        authorizationForOrder: (id) => Promise.resolve(this.orders.get(id) ?? null),
        currentSubscription: (id) => Promise.resolve(rows.get(id) ?? null),
        currentOrderForUser: (id) =>
          Promise.resolve(
            [...rows.values()].find((row) => row.user_id === id)?.provider_order_id ?? null,
          ),
        eventOrderID: (provider, key) => Promise.resolve(events.get(`${provider}:${key}`) ?? null),
        insertEventOnce: (provider, event, subscriptionID) => {
          const key = event.event_key;
          if (key.length > 128) throw new Error("event ledger key too long");
          if (!rows.has(event.provider_order_id)) {
            throw new Error("subscription foreign key missing");
          }
          if (this.failOnEventInsert) throw new Error("db secret: forced rollback");
          if (this.conflictOnEventInsert) return Promise.resolve({ existingOrderID: orderID });
          const identity = `${provider}:${key}`;
          const existingOrderID = events.get(identity);
          if (existingOrderID !== undefined) return Promise.resolve({ existingOrderID });
          events.set(identity, event.provider_order_id);
          recordedEvents.push({
            subscriptionID,
            kind: event.kind,
            userID: event.user_id,
            occurredAt: event.occurred_at,
          });
          return Promise.resolve("inserted" as const);
        },
        saveSubscription: (row) => {
          rows.set(row.provider_order_id, row);
          return Promise.resolve("22222222-2222-2222-2222-222222222222");
        },
      });
      this.rows = rows;
      this.events = events;
      this.recordedEvents = recordedEvents;
      return result;
    } finally {
      release();
    }
  }
}

function processor(repository: MemoryRepository, notification = firstPayment) {
  return processBillingNotification(
    new TextEncoder().encode("provider-raw-callback"),
    new Headers(),
    {
      repository,
      verifier: { verify: () => Promise.resolve(notification) },
    },
  );
}

Deno.test("unverified or oversized callbacks never reach the repository", async () => {
  const repository = new MemoryRepository();
  const rejected = await processBillingNotification(
    new TextEncoder().encode("invalid"),
    new Headers(),
    { repository, verifier: { verify: () => Promise.reject(new Error("raw secret")) } },
  );
  const oversized = await processBillingNotification(
    new Uint8Array(65_537),
    new Headers(),
    {
      repository,
      verifier: {
        verify: () => {
          throw new Error("must not verify");
        },
      },
    },
  );
  assertEquals(rejected, "rejected");
  assertEquals(oversized, "rejected");
  assertEquals(repository.transactions, 0);
});

Deno.test("a verified first payment uses the private order owner and records one event", async () => {
  const repository = new MemoryRepository();
  assertEquals(await processor(repository), "applied");
  assertEquals(repository.rows.get(orderID)?.user_id, userID);
  assertEquals(repository.rows.get(orderID)?.status, "active");
  assertEquals(repository.events.has("ecpay:charge-1"), true);
  assertEquals(repository.recordedEvents, [{
    subscriptionID: "22222222-2222-2222-2222-222222222222",
    kind: "payment_succeeded",
    userID,
    occurredAt: firstPayment.occurredAt,
  }]);
  assertEquals(await processor(repository), "duplicate");
  assertEquals(repository.rows.get(orderID)?.revision, 1);
});

Deno.test("unbound order cannot grant Pro even with a verified notification", async () => {
  const repository = new MemoryRepository();
  repository.orders.clear();
  assertEquals(await processor(repository), "reconcile");
  assertEquals(repository.rows.size, 0);
  assertEquals(repository.events.size, 0);
});

Deno.test("a claimed callback user cannot override the private order owner", async () => {
  const repository = new MemoryRepository();
  const claimedUser = "33333333-3333-3333-3333-333333333333";
  const notification = { ...firstPayment, userID: claimedUser };
  assertEquals(await processor(repository, notification), "applied");
  assertEquals(repository.rows.get(orderID)?.user_id, userID);
  assertEquals(repository.recordedEvents[0].userID, userID);
});

Deno.test("a subscription owned by another account is sent to reconciliation", async () => {
  const repository = new MemoryRepository();
  assertEquals(await processor(repository), "applied");
  repository.orders.set(orderID, {
    userID: "33333333-3333-3333-3333-333333333333",
    currency: "TWD",
    amountMinor: 8_000,
  });
  assertEquals(
    await processor(repository, {
      ...firstPayment,
      eventKey: "charge-2",
      paidFrom: firstPayment.paidThrough,
      paidThrough: "2026-12-01T00:00:00.000Z",
    }),
    "reconcile",
  );
  assertEquals(repository.recordedEvents.length, 1);
});

Deno.test("a signed underpayment or wrong currency never grants Pro", async () => {
  const repository = new MemoryRepository();
  assertEquals(await processor(repository, { ...firstPayment, amountMinor: 100 }), "reconcile");
  assertEquals(await processor(repository, { ...firstPayment, currency: "USD" }), "reconcile");
  assertEquals(repository.rows.size, 0);
  assertEquals(repository.events.size, 0);
});

Deno.test("concurrent redelivery is idempotent and persists only one charge", async () => {
  const repository = new MemoryRepository();
  const results = await Promise.all([processor(repository), processor(repository)]);
  assertEquals(results.sort(), ["applied", "duplicate"]);
  assertEquals(repository.events.size, 1);
  assertEquals(repository.rows.get(orderID)?.revision, 1);
});

Deno.test("a maximum-length provider event ID still fits the ledger column", async () => {
  const repository = new MemoryRepository();
  assertEquals(
    await processor(repository, { ...firstPayment, eventKey: "x".repeat(128) }),
    "applied",
  );
});

Deno.test("a failed ledger insert rolls back the newly written subscription", async () => {
  const repository = new MemoryRepository();
  repository.failOnEventInsert = true;
  assertEquals(await processor(repository), "unavailable");
  assertEquals(repository.rows.size, 0);
  assertEquals(repository.events.size, 0);
  repository.failOnEventInsert = false;
  assertEquals(await processor(repository), "applied");
});

Deno.test("a ledger uniqueness race rolls back the subscription update", async () => {
  const repository = new MemoryRepository();
  repository.conflictOnEventInsert = true;
  assertEquals(await processor(repository), "duplicate");
  assertEquals(repository.rows.size, 0);
  assertEquals(repository.events.size, 0);
});

Deno.test("out-of-order charge after cancellation waits for reconciliation", async () => {
  const repository = new MemoryRepository();
  assertEquals(await processor(repository), "applied");
  assertEquals(
    await processor(repository, {
      ...firstPayment,
      eventKey: "cancel-1",
      kind: "cancellation_confirmed",
      occurredAt: "2026-10-15T00:00:00.000Z",
    }),
    "applied",
  );
  assertEquals(
    await processor(repository, {
      ...firstPayment,
      eventKey: "charge-2",
      occurredAt: "2026-11-01T00:00:00.000Z",
      paidFrom: "2026-11-01T00:00:00.000Z",
      paidThrough: "2026-12-01T00:00:00.000Z",
    }),
    "reconcile",
  );
  assertEquals(repository.rows.get(orderID)?.status, "cancelled");
  assertEquals(repository.events.has("ecpay:charge-2"), false);
});

Deno.test("an event key replayed for another order needs reconciliation", async () => {
  const repository = new MemoryRepository();
  const otherOrder = "order-2";
  repository.orders.set(otherOrder, {
    userID: "33333333-3333-3333-3333-333333333333",
    currency: "TWD",
    amountMinor: 8_000,
  });
  assertEquals(await processor(repository), "applied");
  assertEquals(await processor(repository, { ...firstPayment, orderID: otherOrder }), "reconcile");
  assertEquals(repository.rows.has(otherOrder), false);
  assertEquals(repository.recordedEvents.length, 1);
});

Deno.test("a second current order for one account cannot replace the first", async () => {
  const repository = new MemoryRepository();
  const otherOrder = "order-2";
  repository.orders.set(otherOrder, { userID, currency: "TWD", amountMinor: 8_000 });
  assertEquals(await processor(repository), "applied");
  assertEquals(
    await processor(repository, { ...firstPayment, eventKey: "charge-2", orderID: otherOrder }),
    "reconcile",
  );
  assertEquals(repository.rows.has(otherOrder), false);
  assertEquals(repository.recordedEvents.length, 1);
});
