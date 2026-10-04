import {
  type SubscriptionEvent,
  type SubscriptionRow,
  transitionSubscription,
} from "./subscription.ts";

export type VerifiedBillingNotification = Readonly<{
  provider: "ecpay";
  eventKey: string;
  kind: SubscriptionEvent["kind"];
  orderID: string;
  occurredAt: string;
  paidFrom?: string;
  paidThrough?: string;
  currency?: string;
  amountMinor?: number;
}>;

export type BillingOrderAuthorization = Readonly<{
  userID: string;
  currency: string;
  amountMinor: number;
}>;

export type BillingNotificationVerifier = Readonly<{
  verify(rawBody: Uint8Array, headers: Headers): Promise<VerifiedBillingNotification>;
}>;

export type BillingEventTransaction = Readonly<{
  authorizationForOrder(orderID: string): Promise<BillingOrderAuthorization | null>;
  currentSubscription(orderID: string): Promise<SubscriptionRow | null>;
  currentOrderForUser(userID: string): Promise<string | null>;
  eventOrderID(provider: "ecpay", eventKey: string): Promise<string | null>;
  eventFactsDigest(provider: "ecpay", eventKey: string): Promise<string | null>;
  insertEventOnce(
    provider: "ecpay",
    event: SubscriptionEvent,
    subscriptionID: string,
    factsDigest?: string,
  ): Promise<"inserted" | { existingOrderID: string }>;
  saveSubscription(row: SubscriptionRow): Promise<string>;
}>;

export type BillingEventRepository = Readonly<{
  // The implementation must serialize conflicting orders and commit event + row atomically.
  transaction<T>(work: (tx: BillingEventTransaction) => Promise<T>): Promise<T>;
}>;

export type BillingEventResult = "applied" | "duplicate" | "reconcile" | "rejected" | "unavailable";

const MAXIMUM_NOTIFICATION_BYTES = 65_536;
const USER_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export class DuplicateBillingEvent extends Error {
  constructor(readonly existingOrderID: string) {
    super("billing event key already recorded");
  }
}

export async function processBillingNotification(
  rawBody: Uint8Array,
  headers: Headers,
  dependencies: Readonly<{
    verifier: BillingNotificationVerifier;
    repository: BillingEventRepository;
    factsDigest?: string;
  }>,
): Promise<BillingEventResult> {
  if (rawBody.byteLength === 0 || rawBody.byteLength > MAXIMUM_NOTIFICATION_BYTES) {
    return "rejected";
  }

  let notification: VerifiedBillingNotification;
  try {
    notification = await dependencies.verifier.verify(rawBody, headers);
  } catch {
    return "rejected";
  }
  if (
    notification.provider !== "ecpay" ||
    !notification.eventKey || notification.eventKey.length > 128 ||
    !notification.orderID || notification.orderID.length > 20
  ) return "rejected";

  try {
    return await dependencies.repository.transaction((tx) =>
      applyVerifiedBillingEvent(tx, notification, dependencies.factsDigest)
    );
  } catch (error) {
    if (error instanceof DuplicateBillingEvent) {
      // The competing insert must roll back the subscription first. Digest-aware
      // callers cannot call it a duplicate until the other facts are reviewed.
      return dependencies.factsDigest !== undefined
        ? "reconcile"
        : error.existingOrderID === notification.orderID
        ? "duplicate"
        : "reconcile";
    }
    return "unavailable";
  }
}

// Caller owns the transaction; exceptions must escape to roll back all writes.
export async function applyVerifiedBillingEvent(
  tx: BillingEventTransaction,
  notification: VerifiedBillingNotification,
  factsDigest?: string,
): Promise<BillingEventResult> {
  if (factsDigest !== undefined && !/^[0-9a-f]{64}$/.test(factsDigest)) return "rejected";
  const authorization = await tx.authorizationForOrder(notification.orderID);
  if (authorization === null || !USER_ID_PATTERN.test(authorization.userID)) return "reconcile";
  if (notification.kind === "payment_succeeded" || notification.kind === "refund_confirmed") {
    if (
      !Number.isSafeInteger(authorization.amountMinor) || authorization.amountMinor <= 0 ||
      notification.amountMinor !== authorization.amountMinor ||
      notification.currency !== authorization.currency
    ) return "reconcile";
  }

  const existingOrderID = await tx.eventOrderID(notification.provider, notification.eventKey);
  if (existingOrderID !== null) {
    if (
      factsDigest !== undefined &&
      await tx.eventFactsDigest(notification.provider, notification.eventKey) !== factsDigest
    ) return "reconcile";
    return existingOrderID === notification.orderID ? "duplicate" : "reconcile";
  }

  const event: SubscriptionEvent = {
    event_key: notification.eventKey,
    kind: notification.kind,
    user_id: authorization.userID,
    provider_order_id: notification.orderID,
    occurred_at: notification.occurredAt,
    ...(notification.paidFrom === undefined ? {} : { paid_from: notification.paidFrom }),
    ...(notification.paidThrough === undefined ? {} : { paid_through: notification.paidThrough }),
  };
  const previous = await tx.currentSubscription(notification.orderID);
  if (previous === null) {
    const currentOrder = await tx.currentOrderForUser(authorization.userID);
    if (currentOrder !== null && currentOrder !== notification.orderID) return "reconcile";
  }
  const transition = transitionSubscription(previous, event, new Set());
  if (transition.result !== "applied" || transition.row === null) return "reconcile";

  const subscriptionID = await tx.saveSubscription(transition.row);
  const insertion = await tx.insertEventOnce(
    notification.provider,
    event,
    subscriptionID,
    factsDigest,
  );
  if (insertion !== "inserted") {
    throw new DuplicateBillingEvent(insertion.existingOrderID);
  }
  return "applied";
}
