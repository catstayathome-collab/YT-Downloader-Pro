import type { BillingProvider } from "./billing_management.ts";

// Local fixture only: no HTTP requests, payment URL, credentials or real charges.
export function createMockBillingProvider(): BillingProvider {
  return {
    mode: "mock",
    createCheckout(_command, signal) {
      signal.throwIfAborted();
      return Promise.resolve("confirmed");
    },
    cancelSubscription(_command, signal) {
      signal.throwIfAborted();
      return Promise.resolve("confirmed");
    },
  };
}
