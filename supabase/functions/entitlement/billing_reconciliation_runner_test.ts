import {
  type RecoveryDependencies,
  type RecoveryTimers,
  runRecoveryBatch,
} from "./billing_reconciliation_runner.ts";
import type { RecoverySnapshot } from "./billing_reconciliation.ts";
import fixture from "./test-fixtures/ecpay/queries.json" with { type: "json" };

function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}
const user = "11111111-1111-4111-8111-111111111111";
const id = "22222222-2222-4222-8222-222222222222";
const other = "33333333-3333-4333-8333-333333333333";
const wire = (value: unknown) => new TextEncoder().encode(JSON.stringify(value));
const empty = { ...fixture, authorizations: [] };
function harness() {
  let state: RecoverySnapshot = {
    userID: user,
    operation: {
      id,
      requestID: other,
      orderID: fixture.orderID,
      kind: "checkout",
      state: "unknown",
    },
    subscription: null,
    stateToken: "before",
  };
  let queries = 0, applies = 0, reads = 0, loads = 0;
  const deps: RecoveryDependencies = {
    repository: {
      snapshot: () => {
        reads++;
        return Promise.resolve(structuredClone(state));
      },
      apply: () => {
        applies++;
        state = {
          ...state,
          operation: { ...state.operation, state: "succeeded" },
          stateToken: "after",
        };
        return Promise.resolve("applied");
      },
    },
    query: {
      mode: "mock",
      lookup: () => {
        queries++;
        return Promise.resolve(wire(empty));
      },
    },
    loadOrder: () => {
      loads++;
      return Promise.resolve({
        userID: user,
        merchantID: fixture.merchantID,
        orderID: fixture.orderID,
        currency: "TWD",
        amountMinor: 8000,
      });
    },
    resolvePeriod: () => Promise.resolve(null),
    now: () => new Date("2026-09-28T00:00:00Z"),
  };
  return {
    deps,
    count: () => ({ queries, applies, reads, loads }),
    state: () => state,
    setState: (s: RecoverySnapshot) => {
      state = s;
    },
  };
}
async function rejected(work: Promise<unknown>) {
  try {
    await work;
  } catch {
    return;
  }
  throw new Error("Expected invalid batch rejection");
}
Deno.test("batch rejects invalid IDs oversized lists and real provider before any dependency", async () => {
  const h = harness();
  await rejected(runRecoveryBatch("invalid", [id], h.deps));
  await rejected(runRecoveryBatch(user, ["invalid"], h.deps));
  await rejected(runRecoveryBatch(user, Array(21).fill(id), h.deps));
  await rejected(
    runRecoveryBatch(user, [id], { ...h.deps, query: { ...h.deps.query, mode: "live" as "mock" } }),
  );
  equal(h.count(), { queries: 0, applies: 0, reads: 0, loads: 0 });
});
Deno.test("duplicate operation IDs query once and confirm only through repository", async () => {
  const h = harness();
  equal(await runRecoveryBatch(user, [id, id], h.deps), [{ operationID: id, result: "applied" }]);
  equal(h.count(), { queries: 1, applies: 1, reads: 2, loads: 1 });
  equal(await runRecoveryBatch(user, [], h.deps), []);
});
Deno.test("missing foreign or mismatched operation and order never query", async () => {
  for (const missing of [true, false]) {
    const h = harness();
    const deps = {
      ...h.deps,
      repository: {
        ...h.deps.repository,
        snapshot: () => Promise.resolve(missing ? null : { ...h.state(), userID: other }),
      },
    };
    equal(await runRecoveryBatch(user, [id], deps), [{ operationID: id, result: "needs_review" }]);
    equal(h.count().queries, 0);
  }
  for (const change of [{ userID: other }, { orderID: "OTHER" }]) {
    const h = harness();
    const facts = await h.deps.loadOrder(user, fixture.orderID);
    equal(
      await runRecoveryBatch(user, [id], {
        ...h.deps,
        loadOrder: () => Promise.resolve({ ...facts!, ...change }),
      }),
      [{ operationID: id, result: "needs_review" }],
    );
    equal(h.count().queries, 0);
  }
  const h = harness();
  h.setState({ ...h.state(), operation: { ...h.state().operation, id: other } });
  equal(await runRecoveryBatch(user, [id], h.deps), [{ operationID: id, result: "needs_review" }]);
  equal(h.count().queries, 0);
});
class Clock implements RecoveryTimers {
  elapsed = 0;
  next = 0;
  pending = new Map<number, { at: number; callback: () => void }>();
  setTimeout(callback: () => void, milliseconds: number) {
    const id = ++this.next;
    this.pending.set(id, { at: this.elapsed + milliseconds, callback });
    return id;
  }
  clearTimeout(handle: unknown) {
    this.pending.delete(handle as number);
  }
  advance(ms: number) {
    this.elapsed += ms;
    for (const [id, t] of this.pending) {
      if (t.at <= this.elapsed) {
        this.pending.delete(id);
        t.callback();
      }
    }
  }
}
async function flush() {
  for (let i = 0; i < 20; i++) await Promise.resolve();
}
Deno.test("five second deadline aborts query and late success or rejection cannot write", async () => {
  for (const lateFailure of [false, true]) {
    const h = harness(), clock = new Clock();
    let signal: AbortSignal | undefined;
    let finish!: (b: Uint8Array) => void, fail!: (e: Error) => void;
    const deferred = new Promise<Uint8Array>((resolve, reject) => {
      finish = resolve;
      fail = reject;
    });
    let settled = false;
    const running = runRecoveryBatch(user, [id], {
      ...h.deps,
      timers: clock,
      query: {
        mode: "mock",
        lookup: (_id, s) => {
          signal = s;
          return deferred;
        },
      },
    }).then((value) => {
      settled = true;
      return value;
    });
    await flush();
    clock.advance(4999);
    await flush();
    equal(settled, false);
    clock.advance(1);
    equal(await running, [{ operationID: id, result: "unavailable" }]);
    equal(signal?.aborted, true);
    equal(clock.pending.size, 0);
    if (lateFailure) fail(new Error("SECRET"));
    else finish(wire(empty));
    await flush();
    equal(h.count().applies, 0);
  }
});
Deno.test("query exceptions invalid incomplete and simulation responses never apply", async () => {
  for (
    const response of [
      new Uint8Array([255]),
      wire({ ...empty, complete: false }),
      wire({ mode: "mock", kind: "not_found" }),
      wire({ ...fixture, authorizations: [{ ...fixture.authorizations[0], simulated: true }] }),
    ]
  ) {
    const h = harness();
    const result = await runRecoveryBatch(user, [id], {
      ...h.deps,
      query: { mode: "mock", lookup: () => Promise.resolve(response) },
    });
    equal(["unavailable", "needs_review"].includes(result[0]?.result), true);
    equal(h.count().applies, 0);
  }
  const h = harness();
  equal(
    await runRecoveryBatch(user, [id], {
      ...h.deps,
      query: {
        mode: "mock",
        lookup: () => {
          throw new Error("SECRET");
        },
      },
    }),
    [{ operationID: id, result: "unavailable" }],
  );
  equal(h.count().applies, 0);
});
Deno.test("apply errors and stale results stop without retrying the query", async () => {
  for (const status of ["stale", "unavailable", "needs_review", "duplicate"] as const) {
    const h = harness();
    let writes = 0;
    equal(
      await runRecoveryBatch(user, [id], {
        ...h.deps,
        repository: {
          ...h.deps.repository,
          apply: () => {
            writes++;
            return Promise.resolve(status);
          },
        },
      }),
      [{ operationID: id, result: status }],
    );
    equal(writes, 1);
    equal(h.count().queries, 1);
  }
});
Deno.test("unchanged state tokens stop without infinite replay", async () => {
  const h = harness();
  let writes = 0;
  equal(
    await runRecoveryBatch(user, [id], {
      ...h.deps,
      repository: {
        ...h.deps.repository,
        apply: () => {
          writes++;
          return Promise.resolve("applied");
        },
      },
    }),
    [{ operationID: id, result: "needs_review" }],
  );
  equal(writes, 1);
});
Deno.test("runner caps each operation at 121 applies even with changing tokens", async () => {
  const h = harness();
  let writes = 0;
  equal(
    await runRecoveryBatch(user, [id], {
      ...h.deps,
      repository: {
        ...h.deps.repository,
        apply: () => {
          writes++;
          h.setState({ ...h.state(), stateToken: String(writes) });
          return Promise.resolve("applied");
        },
      },
    }),
    [{ operationID: id, result: "needs_review" }],
  );
  equal(writes, 121);
  equal(h.count().queries, 1);
});
Deno.test("recovery stays sequential and never calls global fetch", async () => {
  const original = globalThis.fetch;
  let networkCalls = 0;
  globalThis.fetch = () => {
    networkCalls++;
    throw new Error("network forbidden");
  };
  try {
    const h = harness();
    equal((await runRecoveryBatch(user, [id], h.deps))[0].result, "applied");
    const bad = harness();
    equal(
      (await runRecoveryBatch(user, [id], {
        ...bad.deps,
        query: { mode: "mock", lookup: () => Promise.reject(new Error("offline")) },
      }))[0].result,
      "unavailable",
    );
    equal(networkCalls, 0);
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("cycling tokens and changed ownership after apply stop", async () => {
  for (const foreign of [false, true]) {
    const h = harness();
    let writes = 0;
    const result = await runRecoveryBatch(user, [id], {
      ...h.deps,
      repository: {
        ...h.deps.repository,
        apply: () => {
          writes++;
          h.setState({
            ...h.state(),
            userID: foreign ? other : user,
            stateToken: writes === 1 ? "next" : "before",
          });
          return Promise.resolve("applied");
        },
      },
    });
    equal(result, [{ operationID: id, result: foreign ? "stale" : "needs_review" }]);
    equal(writes, foreign ? 1 : 2);
  }
});
Deno.test("batch waits for the first query before starting the second", async () => {
  const h = harness();
  const started: string[] = [];
  let finish!: (value: Uint8Array) => void;
  const first = new Promise<Uint8Array>((resolve) => {
    finish = resolve;
  });
  const running = runRecoveryBatch(user, [id, other], {
    ...h.deps,
    repository: {
      ...h.deps.repository,
      snapshot: (_user, operationID) =>
        Promise.resolve({
          ...h.state(),
          operation: {
            ...h.state().operation,
            id: operationID,
            orderID: operationID === id ? "first" : "second",
          },
        }),
    },
    loadOrder: (_user, orderID) =>
      Promise.resolve({
        userID: user,
        merchantID: fixture.merchantID,
        orderID,
        currency: "TWD",
        amountMinor: 8000,
      }),
    query: {
      mode: "mock",
      lookup: (orderID) => {
        started.push(orderID);
        return orderID === "first"
          ? first
          : Promise.resolve(wire({ mode: "mock", kind: "not_found" }));
      },
    },
  });
  await flush();
  equal(started, ["first"]);
  finish(wire({ mode: "mock", kind: "not_found" }));
  equal(await running, [{ operationID: id, result: "needs_review" }, {
    operationID: other,
    result: "needs_review",
  }]);
  equal(started, ["first", "second"]);
  equal(h.count().applies, 0);
});
Deno.test("exactly twenty IDs accepted and invalid clock prevents any write", async () => {
  const h = harness();
  const ids = Array.from({ length: 20 }, () => crypto.randomUUID());
  equal(
    (await runRecoveryBatch(user, ids, {
      ...h.deps,
      repository: {
        ...h.deps.repository,
        snapshot: () => Promise.resolve(null),
      },
    })).length,
    20,
  );
  equal(await runRecoveryBatch(user, [id], { ...h.deps, now: () => new Date(NaN) }), [{
    operationID: id,
    result: "unavailable",
  }]);
  equal(h.count().applies, 0);
});
