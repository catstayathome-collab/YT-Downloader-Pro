import {
  createEntitlementHandler,
  type EntitlementDependencies,
  type EntitlementPayload,
} from "./handler.ts";
import type { GrantRow } from "./contract.ts";
import type { SubscriptionRow } from "./subscription.ts";

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message = "values differ"): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

type Fixture = EntitlementDependencies & {
  verifiedTokens: string[];
  loadedUserIDs: string[];
  signedPayloads: EntitlementPayload[];
};

function activeGrant(): GrantRow {
  return {
    user_id: "11111111-1111-1111-1111-111111111111",
    plan: "pro",
    status: "active",
    features: ["unknown.requested-feature"],
    max_video_height: null,
    valid_from: "2026-09-23T00:00:00.000Z",
    valid_until: "2026-09-25T00:00:00.000Z",
    revision: 7,
  };
}

function fixtureDependencies(overrides: Partial<{
  verifiedUserID: string;
  grant: GrantRow | null;
  authenticationError: Error;
  databaseError: Error;
  signingError: Error;
}> = {}): Fixture {
  const verifiedTokens: string[] = [];
  const loadedUserIDs: string[] = [];
  const signedPayloads: EntitlementPayload[] = [];
  const verifiedUserID = overrides.verifiedUserID ?? "11111111-1111-1111-1111-111111111111";
  return {
    issuer: "https://accounts.ytdownloaderpro.example/staging",
    audience: "com.tachouweng.ytdownloaderpro2",
    verifiedTokens,
    loadedUserIDs,
    signedPayloads,
    verifyAccessToken(token: string): Promise<string> {
      verifiedTokens.push(token);
      if (overrides.authenticationError) return Promise.reject(overrides.authenticationError);
      return Promise.resolve(verifiedUserID);
    },
    loadGrant(userID: string): Promise<GrantRow | null> {
      loadedUserIDs.push(userID);
      if (overrides.databaseError) return Promise.reject(overrides.databaseError);
      return Promise.resolve(overrides.grant === undefined ? activeGrant() : overrides.grant);
    },
    sign(payload: EntitlementPayload): Promise<string> {
      signedPayloads.push(payload);
      if (overrides.signingError) return Promise.reject(overrides.signingError);
      return Promise.resolve("signed-entitlement");
    },
    now: () => new Date("2026-09-24T00:00:00.000Z"),
    randomUUID: () => "22222222-2222-2222-2222-222222222222",
  };
}

function request(options: {
  method?: string;
  authorization?: string;
  contentType?: string;
  body?: unknown;
} = {}): Request {
  return new Request("https://staging-ref.supabase.co/functions/v1/entitlement", {
    method: options.method ?? "POST",
    headers: {
      Authorization: options.authorization ?? "Bearer memory-only-access",
      "Content-Type": options.contentType ?? "application/json",
    },
    body: options.method === "GET"
      ? undefined
      : JSON.stringify(options.body ?? { schema: 1, platform: "macos" }),
  });
}

Deno.test("handler derives exact claims only from verified bearer identity", async () => {
  const dependencies = fixtureDependencies();
  const response = await createEntitlementHandler(dependencies)(request());

  assertEquals(response.status, 200);
  assertEquals(response.headers.get("Cache-Control"), "no-store");
  assertEquals(response.headers.get("Content-Type"), "application/json; charset=utf-8");
  assertEquals(await response.json(), { token: "signed-entitlement" });
  assertEquals(dependencies.verifiedTokens, ["memory-only-access"]);
  assertEquals(dependencies.loadedUserIDs, ["11111111-1111-1111-1111-111111111111"]);
  assertEquals(dependencies.signedPayloads, [{
    iss: "https://accounts.ytdownloaderpro.example/staging",
    aud: "com.tachouweng.ytdownloaderpro2",
    sub: "11111111-1111-1111-1111-111111111111",
    iat: 1_790_208_000,
    nbf: 1_790_207_970,
    exp: 1_790_294_400,
    jti: "22222222-2222-2222-2222-222222222222",
    schema: 1,
    plan: "pro",
    features: [
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
    ],
    maxVideoHeight: null,
    subscriptionState: "active",
    grantRevision: 7,
  }]);
});

Deno.test("handler never grants another user's Pro record to the authenticated subject", async () => {
  const dependencies = fixtureDependencies({
    verifiedUserID: "22222222-2222-2222-2222-222222222222",
    grant: activeGrant(),
  });

  const response = await createEntitlementHandler(dependencies)(request());

  assertEquals(response.status, 200);
  assertEquals(dependencies.loadedUserIDs, ["22222222-2222-2222-2222-222222222222"]);
  assertEquals(dependencies.signedPayloads[0].sub, "22222222-2222-2222-2222-222222222222");
  assertEquals(dependencies.signedPayloads[0].plan, "free");
  assertEquals(dependencies.signedPayloads[0].subscriptionState, "none");
});

Deno.test("handler rejects request-selected identity plan and unknown keys before authentication", async () => {
  const dependencies = fixtureDependencies();
  const response = await createEntitlementHandler(dependencies)(request({
    body: { schema: 1, platform: "macos", userID: "attacker", plan: "pro" },
  }));

  assertEquals(response.status, 400);
  assertEquals(dependencies.verifiedTokens, []);
  assertEquals(dependencies.loadedUserIDs, []);
  assertEquals((await response.json() as { code: string }).code, "invalid_request");
});

Deno.test("handler returns bounded unauthorized without echoing bearer or provider error", async () => {
  const dependencies = fixtureDependencies({ authenticationError: new Error("raw-secret") });
  const response = await createEntitlementHandler(dependencies)(request({
    authorization: "Bearer sensitive-token",
  }));
  const text = await response.text();

  assertEquals(response.status, 401);
  assert(text.includes("unauthorized"), "bounded code must be present");
  assert(!text.includes("sensitive-token"), "bearer must be absent");
  assert(!text.includes("raw-secret"), "provider error must be absent");
});

Deno.test("handler rejects method content type malformed body and missing bearer", async () => {
  const dependencies = fixtureDependencies();
  const cases = [
    request({ method: "GET" }),
    request({ contentType: "text/plain" }),
    request({ body: { schema: 2, platform: "macos" } }),
    request({ body: { schema: 1, platform: "windows" } }),
    request({ authorization: "Basic secret" }),
  ];

  const statuses: number[] = [];
  for (const candidate of cases) {
    statuses.push((await createEntitlementHandler(dependencies)(candidate)).status);
  }
  assertEquals(statuses, [405, 400, 400, 400, 401]);
  assertEquals(dependencies.loadedUserIDs, []);
});

Deno.test("handler maps database and signing failures to a redacted service response", async () => {
  for (
    const dependencies of [
      fixtureDependencies({ databaseError: new Error("database-row-secret") }),
      fixtureDependencies({ signingError: new Error("private-key-secret") }),
    ]
  ) {
    const response = await createEntitlementHandler(dependencies)(request());
    const text = await response.text();
    assertEquals(response.status, 503);
    assert(text.includes("service_unavailable"), "bounded code must be present");
    assert(!text.includes("secret"), "internal error must be absent");
  }
});

Deno.test("missing grant signs canonical Free claims", async () => {
  const dependencies = fixtureDependencies({ grant: null });
  const response = await createEntitlementHandler(dependencies)(request());

  assertEquals(response.status, 200);
  assertEquals(dependencies.signedPayloads[0].plan, "free");
  assertEquals(dependencies.signedPayloads[0].maxVideoHeight, 720);
  assertEquals(dependencies.signedPayloads[0].grantRevision, 0);
});

Deno.test("subscription source signs a bounded Pro grant and never reads legacy grants", async () => {
  const dependencies = fixtureDependencies();
  const subscription: SubscriptionRow = {
    user_id: "11111111-1111-1111-1111-111111111111",
    provider_order_id: "order-1",
    status: "cancelled",
    paid_from: "2026-08-24T00:00:00.000Z",
    paid_through: "2026-09-21T12:00:00.000Z",
    cancel_confirmed_at: "2026-09-21T00:00:00.000Z",
    revision: 9,
  };
  const loaded: string[] = [];
  const response = await createEntitlementHandler({
    ...dependencies,
    loadSubscription(userID) {
      loaded.push(userID);
      return Promise.resolve(subscription);
    },
  })(request());

  assertEquals(response.status, 200);
  assertEquals(loaded, [subscription.user_id]);
  assertEquals(dependencies.loadedUserIDs, []);
  const payload = dependencies.signedPayloads[0];
  assert(
    payload.schema === 2 && payload.plan === "pro",
    "subscription Pro must use bounded schema 2",
  );
  assertEquals(payload.plan, "pro");
  assertEquals(payload.grantRevision, 9);
  assertEquals(payload.paidThroughMs, Date.parse(subscription.paid_through));
  assertEquals(payload.proAccessEndsAtMs, Date.parse(subscription.paid_through) + 72 * 60 * 60_000);
  assertEquals(payload.exp, Math.ceil(payload.proAccessEndsAtMs / 1_000));
});

Deno.test("subscription source fails closed for another user and refunded access", async () => {
  const dependencies = fixtureDependencies();
  const otherUser: SubscriptionRow = {
    user_id: "33333333-3333-3333-3333-333333333333",
    provider_order_id: "order-1",
    status: "active",
    paid_from: "2026-08-24T00:00:00.000Z",
    paid_through: "2026-10-24T00:00:00.000Z",
    cancel_confirmed_at: null,
    revision: 9,
  };
  for (
    const row of [otherUser, {
      ...otherUser,
      user_id: "11111111-1111-1111-1111-111111111111",
      status: "refunded" as const,
    }]
  ) {
    const response = await createEntitlementHandler({
      ...dependencies,
      loadSubscription: () => Promise.resolve(row),
    })(request());
    assertEquals(response.status, 200);
    assertEquals(dependencies.signedPayloads.at(-1)?.plan, "free");
    assertEquals(dependencies.signedPayloads.at(-1)?.schema, 2);
  }
  assertEquals(dependencies.loadedUserIDs, []);
});

Deno.test("subscription expiry caps active Pro to paid-through milliseconds", async () => {
  const dependencies = fixtureDependencies();
  const userID = "11111111-1111-1111-1111-111111111111";
  const paidThrough = "2026-09-24T00:00:10.250Z";
  const row: SubscriptionRow = {
    user_id: userID,
    provider_order_id: "order-2",
    status: "payment_failed",
    paid_from: "2026-08-24T00:00:00.000Z",
    paid_through: paidThrough,
    cancel_confirmed_at: null,
    revision: 4,
  };
  const handler = createEntitlementHandler({
    ...dependencies,
    loadSubscription: () => Promise.resolve(row),
  });
  assertEquals((await handler(request())).status, 200);
  const payload = dependencies.signedPayloads.at(-1);
  assert(
    payload?.schema === 2 && payload.plan === "pro",
    "active paid grant must use bounded schema",
  );
  assertEquals(payload.paidThroughMs, Date.parse(paidThrough));
  assertEquals(payload.proAccessEndsAtMs, Date.parse(paidThrough));
  assertEquals(payload.exp, 1_790_208_011);

  const expired = createEntitlementHandler({
    ...dependencies,
    now: () => new Date(paidThrough),
    loadSubscription: () => Promise.resolve(row),
  });
  assertEquals((await expired(request())).status, 200);
  assertEquals(dependencies.signedPayloads.at(-1)?.plan, "free");
  assertEquals(dependencies.signedPayloads.at(-1)?.schema, 2);
});
