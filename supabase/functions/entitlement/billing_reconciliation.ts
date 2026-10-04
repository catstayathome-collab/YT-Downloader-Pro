import type { BillingOperation } from "./billing_management.ts";
import { type SubscriptionRow, transitionSubscription } from "./subscription.ts";
import {
  canonicalPaymentInstant,
  type NormalizedPayment,
  normalizeTrustedPaymentFacts,
  type PeriodResolver,
  type TrustedOrderFacts,
} from "./ecpay_billing_normalizer.ts";
export type RecoverySnapshot = {
  userID: string;
  operation: BillingOperation;
  subscription: SubscriptionRow | null;
  stateToken: string;
};
export type RecoveryEvidence = { kind: "unavailable" | "not_found" } | {
  kind: "order";
  merchantID: string;
  orderID: string;
  complete: boolean;
  execution: "active" | "cancelled" | "ended";
  cancelledAt: string | null;
  payments: readonly NormalizedPayment[];
};
export type RecoveryReason =
  | "unavailable"
  | "not_found"
  | "invalid_evidence"
  | "incomplete_history"
  | "conflicting_facts"
  | "missing_period"
  | "missing_cancel_time"
  | "policy_conflict"
  | "still_active"
  | "stale_snapshot";
export type RecoveryDecision =
  | { kind: "needs_review"; reason: RecoveryReason }
  | { kind: "checkout_confirmed" }
  | { kind: "payments"; payments: readonly NormalizedPayment[] }
  | { kind: "cancellation"; occurredAt: string };
function invalid(): never {
  throw new Error("Invalid mock query");
}

// JSON.parse validates grammar; this bounded walk independently rejects repeated
// decoded object keys before its last-key-wins result is allowed to leave here.
function strictJSON(raw: Uint8Array): unknown {
  if (raw.length === 0 || raw.length > 65536) invalid();
  const text = new TextDecoder("utf-8", { fatal: true }).decode(raw);
  const parsed: unknown = JSON.parse(text);
  let pos = 0;
  const space = () => {
    while (/\s/.test(text[pos] ?? "") && pos < text.length) pos++;
  };
  function string(): string {
    const start = pos++;
    while (pos < text.length) {
      if (text[pos] === "\\") {
        pos += 2;
        continue;
      }
      if (text[pos++] === '"') return JSON.parse(text.slice(start, pos));
    }
    return invalid();
  }
  function value(depth: number): void {
    if (depth > 32) invalid();
    space();
    if (text[pos] === '"') {
      string();
      return;
    }
    if (text[pos] === "{") {
      pos++;
      space();
      const keys = new Set<string>();
      if (text[pos] === "}") {
        pos++;
        return;
      }
      while (true) {
        space();
        const key = string().toLowerCase();
        if (keys.has(key)) invalid();
        keys.add(key);
        space();
        pos++;
        value(depth + 1);
        space();
        if (text[pos++] === "}") break;
      }
    } else if (text[pos] === "[") {
      pos++;
      space();
      if (text[pos] === "]") {
        pos++;
        return;
      }
      while (true) {
        value(depth + 1);
        space();
        if (text[pos++] === "]") break;
      }
    } else while (pos < text.length && !/[\s,}\]]/.test(text[pos])) pos++;
  }
  value(0);
  return parsed;
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) invalid();
  return value as Record<string, unknown>;
}
function keys(value: Record<string, unknown>, allowed: readonly string[]): void {
  const discarded = ["card4no", "card6no", "auth_code", "email"];
  if (Object.keys(value).some((key) => !allowed.includes(key) && !discarded.includes(key))) {
    invalid();
  }
}
function positive(value: unknown): value is string {
  return typeof value === "string" && /^[1-9][0-9]*$/.test(value) &&
    Number.isSafeInteger(Number(value));
}

export async function validateMockQuery(
  raw: Uint8Array,
  order: TrustedOrderFacts,
  resolvePeriod: PeriodResolver,
): Promise<RecoveryEvidence> {
  try {
    order = Object.freeze({ ...order });
    const data = object(strictJSON(raw));
    if (data.mode !== "mock") invalid();
    if (data.kind === "unavailable" || data.kind === "not_found") {
      keys(data, ["mode", "kind"]);
      return { kind: data.kind };
    }
    keys(data, [
      "mode",
      "kind",
      "merchantID",
      "orderID",
      "complete",
      "execution",
      "cancelledAt",
      "authorizations",
    ]);
    if (
      data.kind !== "order" || data.merchantID !== order.merchantID ||
      data.orderID !== order.orderID || typeof data.complete !== "boolean" ||
      !["active", "cancelled", "ended"].includes(String(data.execution)) ||
      !Array.isArray(data.authorizations) || data.authorizations.length > 120
    ) invalid();
    const cancelledAt = data.cancelledAt === null
      ? null
      : typeof data.cancelledAt === "string"
      ? canonicalPaymentInstant(data.cancelledAt)
      : null;
    if (data.cancelledAt !== null && !cancelledAt) invalid();
    if (data.execution !== "cancelled" && cancelledAt !== null) invalid();
    const payments = new Map<string, NormalizedPayment>();
    for (const item of data.authorizations) {
      const a = object(item);
      keys(a, ["authorizationID", "amountTWD", "occurredAt", "outcome", "simulated"]);
      const occurredAt = typeof a.occurredAt === "string"
        ? canonicalPaymentInstant(a.occurredAt)
        : null;
      if (
        !positive(a.authorizationID) || !positive(a.amountTWD) || !occurredAt ||
        a.outcome !== "paid" || a.simulated !== false
      ) invalid();
      const result = await normalizeTrustedPaymentFacts(
        {
          merchantID: order.merchantID,
          orderID: order.orderID,
          authorizationID: a.authorizationID,
          amountTWD: a.amountTWD,
          occurredAt,
          outcome: "paid",
          simulated: false,
        },
        order,
        resolvePeriod,
      );
      if (result.kind !== "payment") invalid();
      const key = result.value.notification.eventKey;
      const previous = payments.get(key);
      if (previous && previous.factsDigest !== result.value.factsDigest) invalid();
      payments.set(key, result.value);
    }
    return {
      kind: "order",
      merchantID: order.merchantID,
      orderID: order.orderID,
      complete: data.complete,
      execution: data.execution as "active" | "cancelled" | "ended",
      cancelledAt,
      payments: Object.freeze(
        [...payments.values()].sort((a, b) =>
          Date.parse(a.notification.paidFrom!) - Date.parse(b.notification.paidFrom!)
        ),
      ),
    };
  } catch {
    return { kind: "unavailable" };
  }
}

export function decideRecovery(
  snapshot: RecoverySnapshot,
  evidence: RecoveryEvidence,
): RecoveryDecision {
  const review = (reason: RecoveryReason): RecoveryDecision => ({ kind: "needs_review", reason });
  if (evidence.kind !== "order") return review(evidence.kind);
  if (!evidence.complete) return review("incomplete_history");
  let row = snapshot.subscription;
  if (
    evidence.orderID !== snapshot.operation.orderID ||
    (row && (row.user_id !== snapshot.userID || row.provider_order_id !== evidence.orderID))
  ) return review("invalid_evidence");
  if (row && !["active", "payment_failed"].includes(row.status)) return review("policy_conflict");
  if (snapshot.operation.kind === "cancel" && evidence.execution !== "cancelled") {
    return review("still_active");
  }
  if (evidence.execution === "cancelled" && !evidence.cancelledAt) {
    return review("missing_cancel_time");
  }
  let lastEnd: string | undefined;
  for (const payment of evidence.payments) {
    const n = payment.notification;
    if (
      n.orderID !== evidence.orderID || n.kind !== "payment_succeeded" || !n.paidFrom ||
      !n.paidThrough
    ) return review("invalid_evidence");
    if (lastEnd && Date.parse(lastEnd) !== Date.parse(n.paidFrom)) return review("missing_period");
    lastEnd = n.paidThrough;
    // Old facts are offered to the atomic ledger for digest verification, not
    // silently trusted as duplicates. Task 5 filters proven committed prefixes.
    if (row && Date.parse(n.paidThrough) <= Date.parse(row.paid_through)) {
      if (Date.parse(n.paidFrom) < Date.parse(row.paid_from)) return review("conflicting_facts");
      continue;
    }
    const next = transitionSubscription(row, {
      event_key: n.eventKey,
      kind: "payment_succeeded",
      user_id: snapshot.userID,
      provider_order_id: n.orderID,
      occurred_at: n.occurredAt,
      paid_from: n.paidFrom,
      paid_through: n.paidThrough,
    }, new Set());
    if (next.result !== "applied") return review("missing_period");
    row = next.row;
  }
  if (evidence.execution === "cancelled") {
    if (!row) return review("policy_conflict");
    const next = transitionSubscription(row, {
      event_key: "mock-cancel-policy",
      kind: "cancellation_confirmed",
      user_id: snapshot.userID,
      provider_order_id: evidence.orderID,
      occurred_at: evidence.cancelledAt!,
    }, new Set());
    if (next.result !== "applied") return review("policy_conflict");
  }
  if (evidence.payments.length) return { kind: "payments", payments: evidence.payments };
  if (evidence.execution === "cancelled") {
    return { kind: "cancellation", occurredAt: evidence.cancelledAt! };
  }
  if (snapshot.operation.kind === "checkout" && evidence.execution === "active") {
    return { kind: "checkout_confirmed" };
  }
  return review("policy_conflict");
}
