import {
  type RecoveryEvidence,
  type RecoverySnapshot,
  validateMockQuery,
} from "./billing_reconciliation.ts";
import type { PeriodResolver, TrustedOrderFacts } from "./ecpay_billing_normalizer.ts";
import type { RecoveryResult } from "./postgres_billing_reconciliation_repository.ts";

export type MockBillingQuery = Readonly<{
  mode: "mock";
  lookup(orderID: string, signal: AbortSignal): Promise<Uint8Array>;
}>;
export type RecoveryTimers = Readonly<{
  setTimeout(callback: () => void, milliseconds: number): unknown;
  clearTimeout(handle: unknown): void;
}>;
export type RecoveryDependencies = Readonly<{
  repository: {
    snapshot(userID: string, operationID: string): Promise<RecoverySnapshot | null>;
    apply(
      snapshot: RecoverySnapshot,
      evidence: RecoveryEvidence,
      observedAt: Date,
    ): Promise<RecoveryResult>;
  };
  query: MockBillingQuery;
  loadOrder(userID: string, orderID: string): Promise<TrustedOrderFacts | null>;
  resolvePeriod: PeriodResolver;
  now(): Date;
  timers?: RecoveryTimers;
}>;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const timers: RecoveryTimers = {
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (handle) => clearTimeout(handle as number),
};
function owned(
  snapshot: RecoverySnapshot | null,
  userID: string,
  operationID: string,
): snapshot is RecoverySnapshot {
  return snapshot !== null && snapshot.userID === userID && snapshot.operation.id === operationID &&
    !!snapshot.stateToken && !!snapshot.operation.orderID &&
    snapshot.operation.orderID.length <= 20 &&
    (!snapshot.subscription ||
      (snapshot.subscription.user_id === userID &&
        snapshot.subscription.provider_order_id === snapshot.operation.orderID));
}
async function lookup(
  query: MockBillingQuery,
  orderID: string,
  clock: RecoveryTimers,
): Promise<Uint8Array> {
  const controller = new AbortController();
  let handle: unknown;
  try {
    const deadline = new Promise<never>((_resolve, reject) => {
      handle = clock.setTimeout(() => {
        controller.abort();
        reject(new Error("query unavailable"));
      }, 5000);
    });
    // A late result/rejection is consumed by the race, with no write continuation.
    const raw = await Promise.race([
      Promise.resolve().then(() => query.lookup(orderID, controller.signal)),
      deadline,
    ]);
    if (controller.signal.aborted || !(raw instanceof Uint8Array) || raw.length > 65536) {
      throw new Error("query unavailable");
    }
    return raw.slice();
  } finally {
    clock.clearTimeout(handle);
    controller.abort();
  }
}
async function runOne(
  userID: string,
  operationID: string,
  d: RecoveryDependencies,
): Promise<RecoveryResult> {
  try {
    const found = await d.repository.snapshot(userID, operationID);
    if (!owned(found, userID, operationID)) return "needs_review";
    let snapshot = structuredClone(found);
    const loaded = await d.loadOrder(userID, snapshot.operation.orderID);
    if (!loaded || loaded.userID !== userID || loaded.orderID !== snapshot.operation.orderID) {
      return "needs_review";
    }
    const order = Object.freeze({ ...loaded });
    const raw = await lookup(d.query, order.orderID, d.timers ?? timers);
    const evidence = await validateMockQuery(raw, order, d.resolvePeriod);
    if (evidence.kind === "unavailable") return "unavailable";
    if (evidence.kind !== "order" || !evidence.complete) return "needs_review";
    const seen = new Set([snapshot.stateToken]);
    for (let attempt = 0; attempt < 121; attempt++) {
      const observed = d.now();
      if (!Number.isFinite(observed.getTime())) return "unavailable";
      const result = await d.repository.apply(snapshot, evidence, observed);
      if (result !== "applied") return result;
      const next = await d.repository.snapshot(userID, operationID);
      if (!owned(next, userID, operationID) || next.operation.orderID !== order.orderID) {
        return "stale";
      }
      if (seen.has(next.stateToken)) return "needs_review";
      if (snapshot.operation.state !== "succeeded" && next.operation.state === "succeeded") {
        return "applied";
      }
      seen.add(next.stateToken);
      snapshot = structuredClone(next);
    }
    return "needs_review";
  } catch {
    return "unavailable";
  }
}
export async function runRecoveryBatch(
  userID: string,
  operationIDs: readonly string[],
  dependencies: RecoveryDependencies,
): Promise<ReadonlyArray<{ operationID: string; result: RecoveryResult }>> {
  if (
    !UUID.test(userID) || operationIDs.length > 20 || operationIDs.some((id) => !UUID.test(id)) ||
    dependencies.query.mode !== "mock"
  ) throw new Error("Invalid mock recovery batch");
  const ids = [...new Set(operationIDs.map((id) => id.toLowerCase()))];
  const results: Array<{ operationID: string; result: RecoveryResult }> = [];
  for (const operationID of ids) {
    results.push({
      operationID,
      result: await runOne(userID.toLowerCase(), operationID, dependencies),
    });
  }
  return results;
}
