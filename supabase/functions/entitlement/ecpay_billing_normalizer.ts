import type { CandidatePayment, VerifiedCandidate } from "./ecpay_aio_notification.ts";
import type { VerifiedBillingNotification } from "./billing_event_processor.ts";
export type TrustedOrderFacts = Readonly<
  { userID: string; merchantID: string; orderID: string; currency: "TWD"; amountMinor: number }
>;
export type PeriodResolver = (
  identity: { merchantID: string; orderID: string; authorizationID: string },
) => Promise<{ from: string; through: string } | null>;
export type NormalizedPayment = Readonly<
  { notification: VerifiedBillingNotification; factsDigest: string }
>;
export type NormalizationReason =
  | "simulated"
  | "unsuccessful"
  | "order_mismatch"
  | "amount_mismatch"
  | "period_unavailable"
  | "invalid_period";
export type NormalizationResult = Readonly<
  { kind: "payment"; value: NormalizedPayment } | {
    kind: "needs_review";
    reason: NormalizationReason;
  }
>;

async function digest(tuple: readonly unknown[]): Promise<string> {
  const bytes = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify(tuple)),
  );
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function authorizationEventKey(
  merchantID: string,
  orderID: string,
  authorizationID: string,
): Promise<string> {
  return `aio-v1:${await digest(["aio-auth-v1", merchantID, orderID, authorizationID])}`;
}

// Reject calendar rollover and timezone-free strings before canonicalizing instants.
export function canonicalPaymentInstant(value: string | undefined): string | null {
  if (typeof value !== "string") return null;
  const match =
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|([+-])(\d{2}):(\d{2}))$/
      .exec(value);
  if (!match) return null;
  const [, y, m, d, h, min, s, fraction, zone, sign, zh, zm] = match;
  const [year, month, day, hour, minute, second] = [y, m, d, h, min, s].map(Number);
  if (year < 2000) return null;
  const date = new Date(
    Date.UTC(year, month - 1, day, hour, minute, second, Number((fraction ?? "").padEnd(3, "0"))),
  );
  if (
    date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day || date.getUTCHours() !== hour || date.getUTCMinutes() !== minute ||
    date.getUTCSeconds() !== second
  ) return null;
  if (zone !== "Z") {
    if (Number(zh) > 23 || Number(zm) > 59) return null;
    date.setTime(date.getTime() - (sign === "+" ? 1 : -1) * (Number(zh) * 60 + Number(zm)) * 60000);
  }
  return date.toISOString();
}

export async function paymentFactsDigest(
  notification: VerifiedBillingNotification,
): Promise<string> {
  const occurredAt = canonicalPaymentInstant(notification.occurredAt);
  const from = canonicalPaymentInstant(notification.paidFrom);
  const through = canonicalPaymentInstant(notification.paidThrough);
  if (
    notification.provider !== "ecpay" || notification.kind !== "payment_succeeded" ||
    notification.currency !== "TWD" || !Number.isSafeInteger(notification.amountMinor) ||
    notification.amountMinor! <= 0 || !occurredAt || !from || !through ||
    Date.parse(from) >= Date.parse(through)
  ) {
    throw new Error("Invalid normalized payment facts");
  }
  return await digest([
    "aio-payment-facts-v1",
    notification.provider,
    notification.orderID,
    notification.eventKey,
    notification.kind,
    occurredAt,
    notification.currency,
    notification.amountMinor,
    from,
    through,
  ]);
}

export async function normalizeAioPayment(
  candidate: VerifiedCandidate,
  order: TrustedOrderFacts | null,
  resolvePeriod: PeriodResolver | null,
): Promise<NormalizationResult> {
  return await normalizeTrustedPaymentFacts(candidate, order, resolvePeriod);
}

// Internal adapter for validated mock query facts; does not claim callback authentication.
export async function normalizeTrustedPaymentFacts(
  candidate: CandidatePayment,
  order: TrustedOrderFacts | null,
  resolvePeriod: PeriodResolver | null,
): Promise<NormalizationResult> {
  if (candidate.simulated) return { kind: "needs_review", reason: "simulated" };
  if (candidate.outcome !== "paid") return { kind: "needs_review", reason: "unsuccessful" };
  if (
    !order || order.merchantID !== candidate.merchantID || order.orderID !== candidate.orderID ||
    order.currency !== "TWD" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(order.userID)
  ) return { kind: "needs_review", reason: "order_mismatch" };
  const minor = BigInt(candidate.amountTWD) * 100n;
  if (
    minor > BigInt(Number.MAX_SAFE_INTEGER) || minor <= 0n ||
    !Number.isSafeInteger(order.amountMinor) || Number(minor) !== order.amountMinor
  ) return { kind: "needs_review", reason: "amount_mismatch" };
  if (!resolvePeriod) return { kind: "needs_review", reason: "period_unavailable" };
  let period: { from: string; through: string } | null;
  try {
    period = await resolvePeriod(
      Object.freeze({
        merchantID: candidate.merchantID,
        orderID: candidate.orderID,
        authorizationID: candidate.authorizationID,
      }),
    );
  } catch {
    return { kind: "needs_review", reason: "period_unavailable" };
  }
  if (!period) return { kind: "needs_review", reason: "period_unavailable" };
  const from = canonicalPaymentInstant(period.from),
    through = canonicalPaymentInstant(period.through);
  if (!from || !through || Date.parse(from) >= Date.parse(through)) {
    return { kind: "needs_review", reason: "invalid_period" };
  }
  const notification: VerifiedBillingNotification = Object.freeze({
    provider: "ecpay",
    eventKey: await authorizationEventKey(
      candidate.merchantID,
      candidate.orderID,
      candidate.authorizationID,
    ),
    kind: "payment_succeeded",
    orderID: candidate.orderID,
    occurredAt: candidate.occurredAt,
    paidFrom: from,
    paidThrough: through,
    currency: "TWD",
    amountMinor: Number(minor),
  });
  return {
    kind: "payment",
    value: Object.freeze({ notification, factsDigest: await paymentFactsDigest(notification) }),
  };
}
