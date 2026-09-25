import { deriveSubscriptionAccess, type SubscriptionRow } from "./subscription.ts";

export const CANONICAL_FREE_FEATURES = Object.freeze(
  [
    "download.single",
    "video.standard",
    "audio.mp3",
    "subtitle.basic",
    "recovery.manual",
    "history.local",
    "support.standard",
  ] as const,
);

export const CANONICAL_PRO_FEATURES = Object.freeze(
  [
    "download.single",
    "video.standard",
    "video.hd",
    "video.uhd",
    "audio.mp3",
    "queue.batch",
    "playlist.expand",
    "subtitle.basic",
    "subtitle.advanced",
    "format.presets",
    "recovery.manual",
    "recovery.full",
    "history.local",
    "history.sync",
    "support.standard",
    "support.priority",
  ] as const,
);

export type GrantRow = Readonly<{
  user_id: string;
  plan: "free" | "pro";
  status: "none" | "active" | "suspended";
  features: readonly string[];
  max_video_height: number | null;
  valid_from: string;
  valid_until: string | null;
  revision: number;
}>;

type BaseEntitlementClaims = Readonly<{
  plan: "free" | "pro";
  features: readonly string[];
  maxVideoHeight: number | null;
  subscriptionState: "none" | "active";
  grantRevision: number;
}>;

export type EntitlementClaimsInput =
  | (BaseEntitlementClaims & Readonly<{ schema: 1 }>)
  | (BaseEntitlementClaims & Readonly<{ schema: 2; plan: "free" }>)
  | (
    & BaseEntitlementClaims
    & Readonly<{
      schema: 2;
      plan: "pro";
      paidThroughMs: number;
      proAccessEndsAtMs: number;
    }>
  );

export function canonicalFreeEntitlement(
  _now: Date,
  grantRevision = 0,
): EntitlementClaimsInput {
  return {
    schema: 1,
    plan: "free",
    features: [...CANONICAL_FREE_FEATURES],
    maxVideoHeight: 720,
    subscriptionState: "none",
    grantRevision,
  };
}

export function deriveEntitlement(
  grant: GrantRow | null,
  now: Date,
): EntitlementClaimsInput {
  if (!isConsistentActiveProGrant(grant, now)) {
    return canonicalFreeEntitlement(now, fallbackGrantRevision(grant, now));
  }

  return {
    schema: 1,
    plan: "pro",
    features: [...CANONICAL_PRO_FEATURES],
    maxVideoHeight: null,
    subscriptionState: "active",
    grantRevision: grant.revision,
  };
}

export function deriveSubscriptionEntitlement(
  row: SubscriptionRow | null,
  verifiedUserID: string,
  now: Date,
): EntitlementClaimsInput {
  const access = deriveSubscriptionAccess(row, verifiedUserID, now);
  const paidThroughMs = access.paidThrough === null ? NaN : Date.parse(access.paidThrough);
  const proAccessEndsAtMs = access.proAccessEndsAt === null
    ? NaN
    : Date.parse(access.proAccessEndsAt);
  if (
    access.plan !== "pro" ||
    !Number.isSafeInteger(paidThroughMs) ||
    !Number.isSafeInteger(proAccessEndsAtMs) ||
    ![0, 72 * 60 * 60_000].includes(proAccessEndsAtMs - paidThroughMs)
  ) {
    return { ...canonicalFreeEntitlement(now, access.revision), schema: 2, plan: "free" };
  }
  return {
    schema: 2,
    plan: "pro",
    features: [...CANONICAL_PRO_FEATURES],
    maxVideoHeight: null,
    subscriptionState: "active",
    grantRevision: access.revision,
    paidThroughMs,
    proAccessEndsAtMs,
  };
}

function fallbackGrantRevision(grant: GrantRow | null, now: Date): number {
  if (
    grant === null ||
    !Number.isFinite(now.getTime()) ||
    !Number.isSafeInteger(grant.revision) ||
    grant.revision <= 0
  ) {
    return 0;
  }
  return grant.revision;
}

function isConsistentActiveProGrant(
  grant: GrantRow | null,
  now: Date,
): grant is GrantRow {
  if (
    grant === null ||
    !Number.isFinite(now.getTime()) ||
    grant.plan !== "pro" ||
    grant.status !== "active" ||
    !Array.isArray(grant.features) ||
    !grant.features.every((feature) => typeof feature === "string") ||
    grant.max_video_height !== null ||
    !Number.isSafeInteger(grant.revision) ||
    grant.revision <= 0
  ) {
    return false;
  }

  const validFrom = parseDate(grant.valid_from);
  const validUntil = grant.valid_until === null ? null : parseDate(grant.valid_until);
  if (validFrom === null || (grant.valid_until !== null && validUntil === null)) {
    return false;
  }
  if (validUntil !== null && validUntil <= validFrom) {
    return false;
  }

  const currentTime = now.getTime();
  return currentTime >= validFrom && (validUntil === null || currentTime < validUntil);
}

function parseDate(value: string): number | null {
  if (typeof value !== "string" || value.length === 0) {
    return null;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}
