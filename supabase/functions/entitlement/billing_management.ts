import type { BillingAPIResult, BillingCommand } from "./billing_api.ts";
import { deriveSubscriptionAccess, type SubscriptionRow } from "./subscription.ts";

export const MONTHLY_PRICE = Object.freeze({ currency: "TWD" as const, amountMinor: 8000 });
export type BillingOperation = Readonly<{
  id: string;
  requestID: string;
  orderID: string;
  kind: "checkout" | "cancel";
  state: "pending" | "succeeded" | "unknown";
}>;
export type MutationCommand = Exclude<BillingCommand, { kind: "status" }>;
export type BillingSnapshot = Readonly<{
  subscription: SubscriptionRow | null;
  operations: BillingOperation[];
}>;
export type Preparation =
  | { operation: BillingOperation; acquired: boolean }
  | { conflict: "request_conflict" | "existing_order" | "operation_exists" | "not_found" }
  | { alreadyCancelled: true };

export type BillingManagementRepository = Readonly<{
  snapshot(userID: string): Promise<BillingSnapshot>;
  prepare(
    userID: string,
    command: MutationCommand,
    identifiers: { operationID: string; orderID: string },
    now: Date,
  ): Promise<Preparation>;
  finish(
    userID: string,
    operationID: string,
    outcome: "confirmed" | "unknown",
    now: Date,
  ): Promise<BillingOperation>;
}>;

type ProviderCommand = Readonly<{ operationID: string; orderID: string }>;
export type BillingProvider = Readonly<{
  mode: "mock";
  createCheckout(
    command: ProviderCommand & typeof MONTHLY_PRICE,
    signal: AbortSignal,
  ): Promise<"confirmed" | "pending">;
  cancelSubscription(
    command: ProviderCommand,
    signal: AbortSignal,
  ): Promise<"confirmed" | "pending">;
}>;

export function createBillingManagement(
  dependencies: Readonly<{
    repository: BillingManagementRepository;
    provider: BillingProvider;
    now(): Date;
    randomUUID(): string;
    providerTimeoutMs?: number;
  }>,
) {
  const timeoutMs = dependencies.providerTimeoutMs ?? 5000;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30000) {
    throw new Error("invalid provider timeout");
  }
  function now() {
    const value = dependencies.now();
    if (!Number.isFinite(value.getTime())) throw new Error("invalid clock");
    return value;
  }
  async function status(userID: string): Promise<BillingAPIResult> {
    const snapshot = await dependencies.repository.snapshot(userID);
    return {
      status: 200,
      body: {
        mode: "mock",
        price: MONTHLY_PRICE,
        access: deriveSubscriptionAccess(snapshot.subscription, userID, now()),
        operations: snapshot.operations,
      },
    };
  }
  return async (userID: string, command: BillingCommand): Promise<BillingAPIResult> => {
    if (dependencies.provider.mode !== "mock") throw new Error("real billing is disabled");
    if (command.kind === "status") return await status(userID);
    const prepared = await dependencies.repository.prepare(userID, command, {
      operationID: dependencies.randomUUID(),
      orderID: `m${dependencies.randomUUID().replaceAll("-", "").slice(0, 19)}`,
    }, now());
    if ("conflict" in prepared) {
      return {
        status: prepared.conflict === "not_found" ? 404 : 409,
        body: { code: prepared.conflict },
      };
    }
    if ("alreadyCancelled" in prepared) return await status(userID);
    let operation = prepared.operation;
    if (prepared.acquired) {
      const controller = new AbortController();
      let timer: number | undefined;
      let outcome: "confirmed" | "pending" | "unknown";
      try {
        const expiry = new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => {
            controller.abort();
            reject(new Error("provider timeout"));
          }, timeoutMs);
        });
        const providerCommand = { operationID: operation.id, orderID: operation.orderID };
        const call = operation.kind === "checkout"
          ? dependencies.provider.createCheckout(
            { ...providerCommand, ...MONTHLY_PRICE },
            controller.signal,
          )
          : dependencies.provider.cancelSubscription(providerCommand, controller.signal);
        outcome = await Promise.race([call, expiry]);
        if (outcome !== "confirmed" && outcome !== "pending") outcome = "unknown";
      } catch {
        outcome = "unknown";
      } finally {
        clearTimeout(timer);
      }
      if (outcome !== "pending") {
        operation = await dependencies.repository.finish(userID, operation.id, outcome, now());
      }
    }
    return {
      status: operation.state === "succeeded" ? 200 : 202,
      body: { mode: "mock", operation, price: MONTHLY_PRICE },
    };
  };
}
