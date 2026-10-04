import {
  CANONICAL_FREE_FEATURES,
  CANONICAL_PRO_FEATURES,
  canonicalFreeEntitlement,
  deriveEntitlement,
  type EntitlementClaimsInput,
  type GrantRow,
} from "./contract.ts";

function assertEquals(actual: unknown, expected: unknown, message = "values differ"): void {
  const normalized = (value: unknown): string =>
    JSON.stringify(value, (_key, nested) => nested instanceof Set ? [...nested].sort() : nested);
  if (normalized(actual) !== normalized(expected)) {
    throw new Error(`${message}: ${normalized(actual)} != ${normalized(expected)}`);
  }
}

function activeGrant(overrides: Partial<GrantRow> = {}): GrantRow {
  return {
    user_id: "11111111-1111-1111-1111-111111111111",
    plan: "pro",
    status: "active",
    features: [...CANONICAL_PRO_FEATURES],
    max_video_height: null,
    valid_from: "2026-09-23T00:00:00.000Z",
    valid_until: "2026-09-25T00:00:00.000Z",
    revision: 7,
    ...overrides,
  };
}

Deno.test("missing inactive or non-Pro grant derives canonical Free", () => {
  const now = new Date("2026-09-24T00:00:00.000Z");
  const expected: EntitlementClaimsInput = {
    schema: 1,
    plan: "free",
    features: [
      "download.single",
      "video.standard",
      "audio.mp3",
      "subtitle.basic",
      "recovery.manual",
      "history.local",
      "support.standard",
    ],
    maxVideoHeight: 720,
    subscriptionState: "none",
    grantRevision: 0,
  };

  assertEquals(canonicalFreeEntitlement(now), expected);
  assertEquals(deriveEntitlement(null, now), expected);
  for (
    const grant of [
      activeGrant({ status: "suspended" }),
      activeGrant({ status: "none" }),
      activeGrant({ plan: "free" }),
    ]
  ) {
    assertEquals(deriveEntitlement(grant, now), { ...expected, grantRevision: 7 });
  }
  assertEquals(CANONICAL_FREE_FEATURES, expected.features);
});

Deno.test("only a consistent in-window Pro grant derives canonical Pro", () => {
  const result = deriveEntitlement(activeGrant(), new Date("2026-09-24T00:00:00.000Z"));

  assertEquals(result, {
    schema: 1,
    plan: "pro",
    features: [...CANONICAL_PRO_FEATURES],
    maxVideoHeight: null,
    subscriptionState: "active",
    grantRevision: 7,
  });
});

Deno.test("a well-formed suspended grant keeps its monotonic revision while deriving Free", () => {
  const now = new Date("2026-09-24T00:00:00.000Z");
  const result = deriveEntitlement(activeGrant({ status: "suspended", revision: 8 }), now);

  assertEquals(result, {
    ...canonicalFreeEntitlement(now),
    grantRevision: 8,
  });
});

Deno.test("grant feature input cannot expand or shrink the reviewed Pro matrix", () => {
  const grant = activeGrant({ features: ["download.single", "unknown.super-admin"] });
  const result = deriveEntitlement(grant, new Date("2026-09-24T00:00:00.000Z"));

  assertEquals(result.features, CANONICAL_PRO_FEATURES);
});

Deno.test("malformed inconsistent and out-of-window grants derive Free", () => {
  const now = new Date("2026-09-24T00:00:00.000Z");
  const invalid: GrantRow[] = [
    activeGrant({ valid_from: "invalid" }),
    activeGrant({ valid_until: "invalid" }),
    activeGrant({ valid_from: "2026-09-24T00:00:00.001Z" }),
    activeGrant({ valid_until: "2026-09-24T00:00:00.000Z" }),
    activeGrant({
      valid_from: "2026-09-25T00:00:00.000Z",
      valid_until: "2026-09-24T00:00:00.000Z",
    }),
    activeGrant({ revision: 0 }),
    activeGrant({ revision: 1.5 }),
    activeGrant({ max_video_height: 0 }),
    activeGrant({ max_video_height: 1080 }),
  ];

  for (const grant of invalid) {
    const revision = Number.isSafeInteger(grant.revision) && grant.revision > 0
      ? grant.revision
      : 0;
    assertEquals(
      deriveEntitlement(grant, now),
      canonicalFreeEntitlement(now, revision),
    );
  }
});

Deno.test("a null end date remains valid but an invalid clock fails closed", () => {
  const now = new Date("2026-09-24T00:00:00.000Z");

  assertEquals(deriveEntitlement(activeGrant({ valid_until: null }), now).plan, "pro");
  assertEquals(
    deriveEntitlement(activeGrant(), new Date("invalid")),
    canonicalFreeEntitlement(now),
  );
});
