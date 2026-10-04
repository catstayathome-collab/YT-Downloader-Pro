export type SubscriptionStatus =
  | "active"
  | "cancelled"
  | "payment_failed"
  | "refunded"
  | "revoked";

export type SubscriptionRow = Readonly<{
  user_id: string;
  provider_order_id: string;
  status: SubscriptionStatus;
  paid_from: string;
  paid_through: string;
  cancel_confirmed_at: string | null;
  revision: number;
}>;

export type SubscriptionAccess = Readonly<{
  plan: "free" | "pro";
  status: SubscriptionStatus | "none";
  paidThrough: string | null;
  proAccessEndsAt: string | null;
  revision: number;
}>;

export type SubscriptionEvent = Readonly<{
  event_key: string;
  kind:
    | "payment_succeeded"
    | "payment_failed"
    | "cancellation_confirmed"
    | "refund_confirmed"
    | "revocation_confirmed";
  user_id: string;
  provider_order_id: string;
  occurred_at: string;
  paid_from?: string;
  paid_through?: string;
}>;

export type SubscriptionTransition = Readonly<{
  result: "applied" | "duplicate" | "reconcile";
  row: SubscriptionRow | null;
}>;

const CANCELLATION_BONUS_MS = 72 * 60 * 60 * 1_000;

export function deriveSubscriptionAccess(
  row: SubscriptionRow | null,
  verifiedUserID: string,
  now: Date,
): SubscriptionAccess {
  const free: SubscriptionAccess = {
    plan: "free",
    status: "none",
    paidThrough: null,
    proAccessEndsAt: null,
    revision: 0,
  };
  if (
    row === null ||
    !verifiedUserID ||
    row.user_id !== verifiedUserID ||
    !Number.isFinite(now.getTime()) ||
    !Number.isSafeInteger(row.revision) ||
    row.revision <= 0 ||
    !row.provider_order_id ||
    row.provider_order_id.length > 20
  ) return free;

  const paidFrom = Date.parse(row.paid_from);
  const paidThrough = Date.parse(row.paid_through);
  if (!Number.isFinite(paidFrom) || !Number.isFinite(paidThrough) || paidThrough <= paidFrom) {
    return free;
  }

  if (
    row.status === "cancelled" &&
    (row.cancel_confirmed_at === null || !Number.isFinite(Date.parse(row.cancel_confirmed_at)))
  ) return free;
  if (
    (row.status === "active" || row.status === "payment_failed") &&
    row.cancel_confirmed_at !== null
  ) return free;

  const end = row.status === "cancelled" ? paidThrough + CANCELLATION_BONUS_MS : paidThrough;
  if (!Number.isFinite(new Date(end).getTime())) return free;

  switch (row.status) {
    case "active":
    case "cancelled":
    case "payment_failed":
      return {
        plan: now.getTime() >= paidFrom && now.getTime() < end ? "pro" : "free",
        status: row.status,
        paidThrough: new Date(paidThrough).toISOString(),
        proAccessEndsAt: new Date(end).toISOString(),
        revision: row.revision,
      };
    case "refunded":
    case "revoked":
      return {
        plan: "free",
        status: row.status,
        paidThrough: new Date(paidThrough).toISOString(),
        proAccessEndsAt: null,
        revision: row.revision,
      };
    default:
      return free;
  }
}

export function transitionSubscription(
  row: SubscriptionRow | null,
  event: SubscriptionEvent,
  processedEventKeys: ReadonlySet<string>,
): SubscriptionTransition {
  if (processedEventKeys.has(event.event_key)) return { result: "duplicate", row };

  const reconcile: SubscriptionTransition = { result: "reconcile", row };
  const occurredAt = Date.parse(event.occurred_at);
  if (
    !event.event_key || event.event_key.length > 128 ||
    !event.user_id || !event.provider_order_id || event.provider_order_id.length > 20 ||
    !Number.isFinite(occurredAt)
  ) return reconcile;

  if (row === null) {
    if (event.kind !== "payment_succeeded") return reconcile;
    const period = paymentPeriod(event);
    if (period === null) return reconcile;
    return {
      result: "applied",
      row: {
        user_id: event.user_id,
        provider_order_id: event.provider_order_id,
        status: "active",
        paid_from: period.from,
        paid_through: period.through,
        cancel_confirmed_at: null,
        revision: 1,
      },
    };
  }

  if (
    row.user_id !== event.user_id || row.provider_order_id !== event.provider_order_id ||
    !Number.isSafeInteger(row.revision) || row.revision < 1 ||
    row.revision >= Number.MAX_SAFE_INTEGER
  ) return reconcile;

  switch (event.kind) {
    case "payment_succeeded": {
      if (row.status !== "active" && row.status !== "payment_failed") return reconcile;
      const period = paymentPeriod(event);
      if (period === null || Date.parse(period.from) !== Date.parse(row.paid_through)) {
        return reconcile;
      }
      return {
        result: "applied",
        row: { ...row, status: "active", paid_through: period.through, revision: row.revision + 1 },
      };
    }
    case "payment_failed":
      if (row.status !== "active") return reconcile;
      return {
        result: "applied",
        row: { ...row, status: "payment_failed", revision: row.revision + 1 },
      };
    case "cancellation_confirmed":
      if (
        (row.status !== "active" && row.status !== "payment_failed") ||
        occurredAt > Date.parse(row.paid_through)
      ) return reconcile;
      return {
        result: "applied",
        row: {
          ...row,
          status: "cancelled",
          cancel_confirmed_at: new Date(occurredAt).toISOString(),
          revision: row.revision + 1,
        },
      };
    case "refund_confirmed":
    case "revocation_confirmed":
      if (row.status === "refunded" || row.status === "revoked") return reconcile;
      return {
        result: "applied",
        row: {
          ...row,
          status: event.kind === "refund_confirmed" ? "refunded" : "revoked",
          revision: row.revision + 1,
        },
      };
    default:
      return reconcile;
  }
}

function paymentPeriod(event: SubscriptionEvent): { from: string; through: string } | null {
  if (!event.paid_from || !event.paid_through) return null;
  const from = Date.parse(event.paid_from);
  const through = Date.parse(event.paid_through);
  if (!Number.isFinite(from) || !Number.isFinite(through) || through <= from) return null;
  return { from: new Date(from).toISOString(), through: new Date(through).toISOString() };
}
