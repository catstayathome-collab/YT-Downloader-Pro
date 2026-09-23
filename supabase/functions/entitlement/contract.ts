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

export type EntitlementClaimsInput = Readonly<{
  schema: 1;
  plan: "free" | "pro";
  features: readonly string[];
  maxVideoHeight: number | null;
  subscriptionState: "none" | "active";
  grantRevision: number;
}>;

export function canonicalFreeEntitlement(_now: Date): EntitlementClaimsInput {
  return {
    schema: 1,
    plan: "free",
    features: [...CANONICAL_FREE_FEATURES],
    maxVideoHeight: 720,
    subscriptionState: "none",
    grantRevision: 0,
  };
}

export function deriveEntitlement(
  grant: GrantRow | null,
  now: Date,
): EntitlementClaimsInput {
  if (!isConsistentActiveProGrant(grant, now)) {
    return canonicalFreeEntitlement(now);
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
