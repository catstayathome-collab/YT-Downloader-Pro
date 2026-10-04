import postgres from "postgres";
import {
  processBillingNotification,
  type VerifiedBillingNotification,
} from "./billing_event_processor.ts";
import { createPostgresBillingRepository } from "./postgres_billing_repository.ts";
import { deriveSubscriptionAccess, type SubscriptionRow } from "./subscription.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

const environmentVariable = "YTDP_LOCAL_BILLING_DATABASE_URL";
const permission = await Deno.permissions.query({ name: "env", variable: environmentVariable });
const rawURL = permission.state === "granted" ? Deno.env.get(environmentVariable) : undefined;
if (permission.state === "granted" && !rawURL) {
  throw new Error("set YTDP_LOCAL_BILLING_DATABASE_URL to run database integration tests");
}

function requireLoopbackDatabaseURL(value: string): string {
  const url = new URL(value);
  if (
    !["postgres:", "postgresql:"].includes(url.protocol) ||
    !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
  ) throw new Error("billing integration tests require a local PostgreSQL URL");
  return value;
}

const localURL = rawURL === undefined ? undefined : requireLoopbackDatabaseURL(rawURL);

Deno.test("billing database URL rejects remote hosts and non-Postgres protocols", () => {
  for (
    const candidate of [
      "postgresql://postgres:synthetic@database.example.invalid:5432/postgres",
      "postgresql://localhost@database.example.invalid:5432/postgres",
      "https://127.0.0.1:55432/postgres",
    ]
  ) {
    let rejected = false;
    try {
      requireLoopbackDatabaseURL(candidate);
    } catch {
      rejected = true;
    }
    assertEquals(rejected, true);
  }
});

function testWithDatabase(name: string, fn: (url: string) => Promise<void>): void {
  Deno.test({
    name,
    ignore: localURL === undefined,
    fn: async () => await fn(localURL!),
  });
}

function payment(orderID: string, eventKey: string): VerifiedBillingNotification {
  return {
    provider: "ecpay",
    orderID,
    eventKey,
    kind: "payment_succeeded",
    occurredAt: "2026-10-01T00:00:00.000Z",
    paidFrom: "2026-10-01T00:00:00.000Z",
    paidThrough: "2026-11-01T00:00:00.000Z",
    currency: "TWD",
    amountMinor: 8_000,
  };
}

function process(
  repository: ReturnType<typeof createPostgresBillingRepository>,
  notification: VerifiedBillingNotification,
) {
  return processBillingNotification(new TextEncoder().encode("synthetic"), new Headers(), {
    repository,
    verifier: { verify: () => Promise.resolve(notification) },
  });
}

async function withOrder(
  url: string,
  work: (fixture: {
    sql: ReturnType<typeof postgres>;
    userID: string;
    orderID: string;
    eventKey: string;
  }) => Promise<void>,
): Promise<void> {
  const sql = postgres(url, { prepare: false, max: 2 });
  const userID = crypto.randomUUID();
  const orderID = `t${userID.replaceAll("-", "").slice(0, 18)}`;
  const eventKey = `event-${userID}`;
  try {
    await sql`
      insert into auth.users (id, aud, role, email)
      values (${userID}, 'authenticated', 'authenticated', ${`billing-${userID}@example.invalid`})
    `;
    await sql`
      insert into private.billing_orders
        (provider, provider_order_id, user_id, expected_currency, expected_amount_minor)
      values ('ecpay', ${orderID}, ${userID}, 'TWD', 8000)
    `;
    await work({ sql, userID, orderID, eventKey });
  } finally {
    await sql`
      delete from private.subscription_events
      where subscription_id in
        (select subscription_id from private.subscriptions where user_id = ${userID})
    `;
    await sql`delete from private.subscriptions where user_id = ${userID}`;
    await sql`delete from private.billing_orders where user_id = ${userID}`;
    await sql`delete from auth.users where id = ${userID}`;
    await sql.end();
  }
}

testWithDatabase("first payment persists one linked event and one subscription", async (url) => {
  await withOrder(url, async ({ sql, userID, orderID, eventKey }) => {
    const result = await process(createPostgresBillingRepository(sql), payment(orderID, eventKey));
    assertEquals(result, "applied");
    const rows = await sql`
      select s.user_id, s.revision, s.status, e.event_kind, e.subscription_id
      from private.subscriptions s
      join private.subscription_events e using (subscription_id)
      where s.provider_order_id = ${orderID}
    `;
    assertEquals(rows.length, 1);
    assertEquals(rows[0].user_id, userID);
    assertEquals(Number(rows[0].revision), 1);
    assertEquals(rows[0].status, "active");
    assertEquals(rows[0].event_kind, "payment_succeeded");
    const stored = await createPostgresBillingRepository(sql).transaction((tx) =>
      tx.currentSubscription(orderID)
    );
    assertEquals(stored?.paid_from, "2026-10-01T00:00:00.000Z");
    assertEquals(stored?.paid_through, "2026-11-01T00:00:00.000Z");
    assertEquals(deriveSubscriptionAccess(stored, userID, new Date("2026-10-15")).plan, "pro");
  });
});

testWithDatabase("a failed event insert rolls back its first subscription", async (url) => {
  await withOrder(url, async ({ sql, userID, orderID }) => {
    const repository = createPostgresBillingRepository(sql);
    const row: SubscriptionRow = {
      user_id: userID,
      provider_order_id: orderID,
      status: "active",
      paid_from: "2026-10-01T00:00:00.000Z",
      paid_through: "2026-11-01T00:00:00.000Z",
      cancel_confirmed_at: null,
      revision: 1,
    };
    let code: unknown;
    try {
      await repository.transaction(async (tx) => {
        const subscriptionID = await tx.saveSubscription(row);
        await tx.insertEventOnce("ecpay", {
          event_key: "x".repeat(129),
          kind: "payment_succeeded",
          user_id: userID,
          provider_order_id: orderID,
          occurred_at: "2026-10-01T00:00:00.000Z",
        }, subscriptionID);
      });
    } catch (error) {
      code = (error as { code?: string }).code;
    }
    assertEquals(code, "22001");
    assertEquals(
      (await sql`select 1 from private.subscriptions where user_id = ${userID}`).length,
      0,
    );
    assertEquals(
      (await sql`select 1 from private.subscription_events where provider_event_key = ${
        "x".repeat(129)
      }`).length,
      0,
    );
  });
});

testWithDatabase("independent connections serialize the same first charge", async (url) => {
  await withOrder(url, async ({ sql, orderID, eventKey }) => {
    const second = postgres(url, { prepare: false, max: 2 });
    try {
      const results = await Promise.all([
        process(createPostgresBillingRepository(sql), payment(orderID, eventKey)),
        process(createPostgresBillingRepository(second), payment(orderID, eventKey)),
      ]);
      assertEquals(results.sort(), ["applied", "duplicate"]);
      const rows = await sql`
        select s.revision, count(e.event_id)::integer as event_count
        from private.subscriptions s join private.subscription_events e using (subscription_id)
        where s.provider_order_id = ${orderID} group by s.revision
      `;
      assertEquals(rows.length, 1);
      assertEquals(Number(rows[0].revision), 1);
      assertEquals(rows[0].event_count, 1);
    } finally {
      await second.end();
    }
  });
});

testWithDatabase("independent connections do not extend one renewal twice", async (url) => {
  await withOrder(url, async ({ sql, orderID, eventKey }) => {
    assertEquals(
      await process(createPostgresBillingRepository(sql), payment(orderID, eventKey)),
      "applied",
    );
    const second = postgres(url, { prepare: false, max: 2 });
    const renewal = {
      ...payment(orderID, `${eventKey}-renewal`),
      occurredAt: "2026-11-01T00:00:00.000Z",
      paidFrom: "2026-11-01T00:00:00.000Z",
      paidThrough: "2026-12-01T00:00:00.000Z",
    };
    try {
      const results = await Promise.all([
        process(createPostgresBillingRepository(sql), renewal),
        process(createPostgresBillingRepository(second), renewal),
      ]);
      assertEquals(results.sort(), ["applied", "duplicate"]);
      const rows = await sql`
        select s.revision, s.paid_through, count(e.event_id)::integer as event_count
        from private.subscriptions s join private.subscription_events e using (subscription_id)
        where s.provider_order_id = ${orderID}
        group by s.revision, s.paid_through
      `;
      assertEquals(rows.length, 1);
      assertEquals(Number(rows[0].revision), 2);
      assertEquals(new Date(rows[0].paid_through).toISOString(), renewal.paidThrough);
      assertEquals(rows[0].event_count, 2);
    } finally {
      await second.end();
    }
  });
});

testWithDatabase("one account cannot acquire a second current order", async (url) => {
  await withOrder(url, async ({ sql, userID, orderID, eventKey }) => {
    const repository = createPostgresBillingRepository(sql);
    assertEquals(await process(repository, payment(orderID, eventKey)), "applied");
    const otherOrder = `x${orderID.slice(1)}`;
    await sql`
      insert into private.billing_orders
        (provider, provider_order_id, user_id, expected_currency, expected_amount_minor)
      values ('ecpay', ${otherOrder}, ${userID}, 'TWD', 8000)
    `;
    assertEquals(await process(repository, payment(otherOrder, `${eventKey}-2`)), "reconcile");
    const rows = await sql`
      select provider_order_id from private.subscriptions where user_id = ${userID}
    `;
    assertEquals(rows.length, 1);
    assertEquals(rows[0].provider_order_id, orderID);
  });
});

testWithDatabase(
  "cross-account event-key collision does not grant the second account",
  async (url) => {
    await withOrder(url, async ({ sql, orderID, eventKey }) => {
      const otherUserID = crypto.randomUUID();
      const otherOrderID = `u${otherUserID.replaceAll("-", "").slice(0, 18)}`;
      await sql`
      insert into auth.users (id, aud, role, email)
      values (
        ${otherUserID}, 'authenticated', 'authenticated',
        ${`billing-${otherUserID}@example.invalid`}
      )
    `;
      try {
        await sql`
        insert into private.billing_orders
          (provider, provider_order_id, user_id, expected_currency, expected_amount_minor)
        values ('ecpay', ${otherOrderID}, ${otherUserID}, 'TWD', 8000)
      `;
        const repository = createPostgresBillingRepository(sql);
        assertEquals(await process(repository, payment(orderID, eventKey)), "applied");
        assertEquals(await process(repository, payment(otherOrderID, eventKey)), "reconcile");
        assertEquals(
          (await sql`select 1 from private.subscriptions where user_id = ${otherUserID}`).length,
          0,
        );
      } finally {
        await sql`delete from private.billing_orders where user_id = ${otherUserID}`;
        await sql`delete from auth.users where id = ${otherUserID}`;
      }
    });
  },
);

testWithDatabase("invalid amount and paid period leave financial rows unchanged", async (url) => {
  await withOrder(url, async ({ sql, userID, orderID, eventKey }) => {
    const repository = createPostgresBillingRepository(sql);
    assertEquals(
      await process(repository, { ...payment(orderID, eventKey), amountMinor: 100 }),
      "reconcile",
    );
    assertEquals(
      await process(repository, { ...payment(orderID, eventKey), paidThrough: "invalid" }),
      "reconcile",
    );
    assertEquals(
      await process(repository, { ...payment(orderID, eventKey), currency: "USD" }),
      "reconcile",
    );
    assertEquals(await process(repository, payment("unbound-order", eventKey)), "reconcile");
    assertEquals(
      (await sql`select 1 from private.subscriptions where user_id = ${userID}`).length,
      0,
    );
    assertEquals(
      (await sql`select 1 from private.subscription_events where provider_event_key = ${eventKey}`)
        .length,
      0,
    );
  });
});

testWithDatabase(
  "a callback-supplied account cannot override the stored order owner",
  async (url) => {
    await withOrder(url, async ({ sql, userID, orderID, eventKey }) => {
      await withOrder(url, async ({ userID: otherUserID }) => {
        const repository = createPostgresBillingRepository(sql);
        const claimed = { ...payment(orderID, eventKey), userID: otherUserID };
        assertEquals(await process(repository, claimed), "applied");
        const stored = await repository.transaction((tx) => tx.currentSubscription(orderID));
        assertEquals(stored?.user_id, userID);
        assertEquals(
          deriveSubscriptionAccess(stored, otherUserID, new Date("2026-10-15")).plan,
          "free",
        );
        assertEquals(
          await repository.transaction((tx) => tx.currentOrderForUser(otherUserID)),
          null,
        );
      });
    });
  },
);

testWithDatabase("a mismatched subscription owner is reconciled without mutation", async (url) => {
  await withOrder(url, async ({ sql, userID, orderID, eventKey }) => {
    await withOrder(url, async ({ userID: otherUserID }) => {
      await sql`
        insert into private.subscriptions
          (user_id, provider, provider_order_id, status, paid_from, paid_through)
        values (${otherUserID}, 'ecpay', ${orderID}, 'active', '2026-09-01', '2026-10-01')
      `;
      const repository = createPostgresBillingRepository(sql);
      const before = await repository.transaction((tx) => tx.currentSubscription(orderID));
      assertEquals(await process(repository, payment(orderID, eventKey)), "reconcile");
      const after = await repository.transaction((tx) => tx.currentSubscription(orderID));
      assertEquals(after, before);
      assertEquals(deriveSubscriptionAccess(after, userID, new Date("2026-09-15")).plan, "free");
      assertEquals(await repository.transaction((tx) => tx.eventOrderID("ecpay", eventKey)), null);
    });
  });
});

testWithDatabase("a cross-account insert race rolls back the losing subscription", async (url) => {
  await withOrder(url, async (first) => {
    await withOrder(url, async (second) => {
      // Both real transactions reach event insertion before either can commit.
      const ready = Promise.withResolvers<void>();
      let arrivals = 0;
      const timeout = setTimeout(() => ready.reject(new Error("race barrier timed out")), 5000);
      function synchronized(sql: ReturnType<typeof postgres>) {
        const repository = createPostgresBillingRepository(sql);
        return {
          transaction<T>(work: Parameters<typeof repository.transaction<T>>[0]): Promise<T> {
            return repository.transaction((tx) =>
              work({
                ...tx,
                async insertEventOnce(...args) {
                  if (++arrivals === 2) ready.resolve();
                  await ready.promise;
                  return await tx.insertEventOnce(...args);
                },
              })
            );
          },
        };
      }
      try {
        const results = await Promise.all([
          process(synchronized(first.sql), payment(first.orderID, first.eventKey)),
          process(synchronized(second.sql), payment(second.orderID, first.eventKey)),
        ]);
        assertEquals(results.toSorted(), ["applied", "reconcile"]);
        const winner = results[0] === "applied" ? first : second;
        const loser = results[0] === "applied" ? second : first;
        const subscriptions = await first.sql`
          select user_id, revision from private.subscriptions
          where user_id in (${first.userID}, ${second.userID})
        `;
        assertEquals(subscriptions.length, 1);
        assertEquals(subscriptions[0].user_id, winner.userID);
        assertEquals(Number(subscriptions[0].revision), 1);
        const repository = createPostgresBillingRepository(first.sql);
        assertEquals(
          await repository.transaction((tx) => tx.eventOrderID("ecpay", first.eventKey)),
          winner.orderID,
        );
        assertEquals(
          await repository.transaction((tx) => tx.currentSubscription(loser.orderID)),
          null,
        );
      } finally {
        clearTimeout(timeout);
      }
    });
  });
});

testWithDatabase(
  "concurrent different orders preserve one current order per account",
  async (url) => {
    await withOrder(url, async ({ sql, userID, orderID, eventKey }) => {
      const otherOrder = `x${orderID.slice(1)}`;
      await sql`
      insert into private.billing_orders
        (provider, provider_order_id, user_id, expected_currency, expected_amount_minor)
      values ('ecpay', ${otherOrder}, ${userID}, 'TWD', 8000)
    `;
      const second = postgres(url, { prepare: false, max: 2 });
      try {
        const results = await Promise.all([
          process(createPostgresBillingRepository(sql), payment(orderID, eventKey)),
          process(
            createPostgresBillingRepository(second),
            payment(otherOrder, `${eventKey}-other`),
          ),
        ]);
        assertEquals(results.toSorted(), ["applied", "reconcile"]);
        const rows = await sql`
        select provider_order_id, is_current from private.subscriptions where user_id = ${userID}
      `;
        assertEquals(rows.length, 1);
        assertEquals(rows[0].provider_order_id, results[0] === "applied" ? orderID : otherOrder);
        assertEquals(rows[0].is_current, true);
      } finally {
        await second.end();
      }
    });
  },
);

testWithDatabase(
  "the unique current-order constraint rolls back an earlier event write",
  async (url) => {
    await withOrder(url, async ({ sql, userID, orderID, eventKey }) => {
      const repository = createPostgresBillingRepository(sql);
      assertEquals(await process(repository, payment(orderID, eventKey)), "applied");
      const row = await repository.transaction((tx) => tx.currentSubscription(orderID));
      let code: unknown;
      try {
        await repository.transaction(async (tx) => {
          const id = await tx.saveSubscription({ ...row!, revision: 2 });
          await tx.insertEventOnce("ecpay", {
            event_key: `${eventKey}-rollback`,
            kind: "payment_failed",
            user_id: userID,
            provider_order_id: orderID,
            occurred_at: "2026-10-02T00:00:00Z",
          }, id);
          await tx.saveSubscription({ ...row!, provider_order_id: `x${orderID.slice(1)}` });
        });
      } catch (error) {
        code = (error as { code?: string }).code;
      }
      assertEquals(code, "23505");
      assertEquals(await repository.transaction((tx) => tx.currentSubscription(orderID)), row);
      assertEquals(
        await repository.transaction((tx) => tx.eventOrderID("ecpay", `${eventKey}-rollback`)),
        null,
      );
    });
  },
);
