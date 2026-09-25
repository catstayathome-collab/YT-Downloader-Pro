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
  eventExists(provider: "ecpay", eventKey: string): Promise<boolean>;
  insertEventOnce(
    provider: "ecpay",
    event: SubscriptionEvent,
    subscriptionID: string,
  ): Promise<boolean>;
  saveSubscription(row: SubscriptionRow): Promise<string>;
}>;

export type BillingEventRepository = Readonly<{
  // The implementation must serialize conflicting orders and commit event + row atomically.
  transaction<T>(work: (tx: BillingEventTransaction) => Promise<T>): Promise<T>;
}>;

export type BillingEventResult = "applied" | "duplicate" | "reconcile" | "rejected" | "unavailable";

const MAXIMUM_NOTIFICATION_BYTES = 65_536;
const USER_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
class DuplicateBillingEvent extends Error {}

export async function processBillingNotification(
  rawBody: Uint8Array,
  headers: Headers,
  dependencies: Readonly<{
    verifier: BillingNotificationVerifier;
    repository: BillingEventRepository;
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
    return await dependencies.repository.transaction(async (tx) => {
      const authorization = await tx.authorizationForOrder(notification.orderID);
      if (authorization === null || !USER_ID_PATTERN.test(authorization.userID)) return "reconcile";
      if (notification.kind === "payment_succeeded" || notification.kind === "refund_confirmed") {
        if (
          !Number.isSafeInteger(authorization.amountMinor) || authorization.amountMinor <= 0 ||
          notification.amountMinor !== authorization.amountMinor ||
          notification.currency !== authorization.currency
        ) return "reconcile";
      }

      if (await tx.eventExists(notification.provider, notification.eventKey)) return "duplicate";

      const event: SubscriptionEvent = {
        event_key: notification.eventKey,
        kind: notification.kind,
        user_id: authorization.userID,
        provider_order_id: notification.orderID,
        occurred_at: notification.occurredAt,
        ...(notification.paidFrom === undefined ? {} : { paid_from: notification.paidFrom }),
        ...(notification.paidThrough === undefined
          ? {}
          : { paid_through: notification.paidThrough }),
      };
      const previous = await tx.currentSubscription(notification.orderID);
      const transition = transitionSubscription(previous, event, new Set());
      if (transition.result !== "applied" || transition.row === null) return "reconcile";

      const subscriptionID = await tx.saveSubscription(transition.row);
      if (!(await tx.insertEventOnce(notification.provider, event, subscriptionID))) {
        throw new DuplicateBillingEvent();
      }
      return "applied";
    });
  } catch (error) {
    if (error instanceof DuplicateBillingEvent) return "duplicate";
    return "unavailable";
  }
}
