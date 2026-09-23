# Supabase Google Authentication And Entitlement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (\`- [ ]\`) syntax for tracking.

**Goal:** Add development/staging Google PKCE authentication through Supabase Auth and cryptographically verified server entitlements to the macOS Swift app without enabling payment or production user collection.

**Architecture:** Import only the Supabase Swift Auth product and keep it behind the existing AuthenticationProvider boundary. Supabase SQL and one Edge Function derive and sign entitlement JWS values; app-owned URLSession, CryptoKit, Keychain, PlanController, FeaturePolicy, DownloadStore, and DownloadRunner components fetch, verify, cache, and enforce them without sending media activity to the backend.

**Tech Stack:** macOS 13+, Swift 6.3/Xcode 26.6, SwiftPM, supabase-swift Auth 2.55.2, CryptoKit ES256, XCTest, Supabase PostgreSQL/RLS, Deno 2.7, TypeScript 5.9, supabase-js 2.117.0, Python unittest.

**Spec:** docs/superpowers/specs/2026-09-23-supabase-google-auth-entitlement-design.md

## Global Constraints

- Work from codex/supabase-auth-entitlement-design, which is based on codex/public-macos-2.0.1 commit 8490e96.
- Preserve Free operation without an account or entitlement request.
- Use the macOS system browser and Authorization Code with PKCE; never embed a WKWebView.
- Pin supabase-swift exactly to 2.55.2 and import only the Auth product.
- Pin supabase-js exactly to 2.117.0 for the Edge Function.
- Keep CredentialVault as the only persistent authentication writer; Supabase Auth storage is memory-only.
- Keep access tokens in memory and refresh credentials in the data-protection Keychain.
- Keep the service-role key and ES256 private key out of Swift source, resources, app bundles, tests, logs, and Git.
- Send no media URL, title, cookie, output path, history, thumbnail, or diagnostic content to Supabase.
- Keep public builds free when no approved backend configuration is present.
- Compile the Free/Test Pro switch only under YTDP_INTERNAL_TEST.
- Do not add ECPay, checkout, recurring billing, cancellation, refund, Apple sign-in, history sync, account deletion, support submission, or production deployment.
- Use Traditional Chinese, Japanese, and English for all new user-facing text.
- Run every behavior change through a witnessed failing test, minimal passing implementation, and refactor.
- Do not install Supabase CLI or Docker, create cloud projects, deploy functions, create OAuth credentials, or submit external forms without fresh owner approval.

## Review Focus

1. A malicious configuration URL containing userinfo, query, fragment, HTTP, or a host outside the selected Supabase project must disable network authentication without exposing the value.
2. A verified entitlement for one account must never survive logout or become usable after a different account signs in, even if its signature and expiry are otherwise valid.
3. A stale asynchronous login, refresh, or entitlement response must never overwrite a newer account or higher grant revision.
4. Exact expiry, five-minute clock-skew, and 72-hour offline-grace boundaries must be deterministic and fail to Free outside the accepted window.
5. A verified downgrade during active work may let the active process finish but must restrict queued, retrying, and newly admitted Pro work immediately.

---

### Task 1: Add Fail-Closed Supabase Configuration

**Files:**
- Create: swift-2.0/Sources/YTDownloaderPro2/Authentication/SupabaseAuthConfiguration.swift
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/SupabaseAuthConfigurationTests.swift
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/supabase-staging-configuration.json
- Modify: swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationModels.swift
- Modify: swift-2.0/Package.swift

**Interfaces:**
- Produces: SupabaseAuthConfiguration.load(data:) throws -> SupabaseAuthConfiguration.
- Produces: AuthEnvironment values disabled, mock, staging, and production.
- Produces: AuthEnvironmentResolution.resolve(environment:configuration:) with a safe disabled fallback.
- Consumes later: Task 6 uses the validated authURL, publishableKey, redirectURL, entitlementURL, issuer, audience, and publicKeys.

- [ ] **Step 1: Add a fixture and failing configuration tests**

Create a fixture containing non-secret reserved example values:

~~~json
{
  "schemaVersion": 1,
  "projectURL": "https://staging-ref.supabase.co",
  "publishableKey": "sb_publishable_test_fixture",
  "redirectURL": "com.tachouweng.ytdownloaderpro2://auth/callback",
  "entitlementURL": "https://staging-ref.supabase.co/functions/v1/entitlement",
  "entitlementIssuer": "https://accounts.ytdownloaderpro.example/staging",
  "entitlementAudience": "com.tachouweng.ytdownloaderpro2",
  "publicKeys": {
    "test-es256-2026-09": "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU"
  }
}
~~~

Add tests that:

~~~swift
func testValidStagingConfigurationDerivesExactTrustedEndpoints() throws {
    let configuration = try SupabaseAuthConfiguration.load(data: fixtureData())
    XCTAssertEqual(configuration.authURL.absoluteString, "https://staging-ref.supabase.co/auth/v1")
    XCTAssertEqual(configuration.entitlementURL.absoluteString, "https://staging-ref.supabase.co/functions/v1/entitlement")
    XCTAssertEqual(configuration.redirectURL.scheme, "com.tachouweng.ytdownloaderpro2")
    XCTAssertEqual(configuration.publicKeys.keys.sorted(), ["test-es256-2026-09"])
}

func testConfigurationRejectsEveryUnsafeURLShapeAndSecretKeyPrefix() {
    let cases = [
        mutation("projectURL", "http://staging-ref.supabase.co"),
        mutation("projectURL", "https://user:password@staging-ref.supabase.co"),
        mutation("projectURL", "https://staging-ref.supabase.co?token=secret"),
        mutation("entitlementURL", "https://other.example/functions/v1/entitlement"),
        mutation("redirectURL", "https://staging-ref.supabase.co/auth/callback"),
        mutation("publishableKey", "sb_secret_forbidden")
    ]
    for data in cases {
        XCTAssertThrowsError(try SupabaseAuthConfiguration.load(data: data))
    }
}

func testEnvironmentResolutionEnablesOnlyExactMockOrConfiguredStaging() throws {
    let configuration = try SupabaseAuthConfiguration.load(data: fixtureData())
    XCTAssertEqual(AuthEnvironmentResolution.resolve(environment: [:], configuration: nil).environment, .disabled)
    XCTAssertEqual(AuthEnvironmentResolution.resolve(environment: ["YTDP_AUTH_MODE": "mock"], configuration: nil).environment, .mock)
    XCTAssertEqual(AuthEnvironmentResolution.resolve(environment: ["YTDP_AUTH_MODE": "staging"], configuration: configuration).environment, .staging)
    XCTAssertEqual(AuthEnvironmentResolution.resolve(environment: ["YTDP_AUTH_MODE": "STAGING"], configuration: configuration).environment, .disabled)
    XCTAssertEqual(AuthEnvironmentResolution.resolve(environment: ["YTDP_AUTH_MODE": "staging"], configuration: nil).environment, .disabled)
}
~~~

- [ ] **Step 2: Run the focused tests and witness the expected failure**

Run:

~~~sh
cd swift-2.0
swift test --filter SupabaseAuthConfigurationTests
~~~

Expected: compilation fails because SupabaseAuthConfiguration and AuthEnvironmentResolution do not exist and AuthEnvironment has no staging case.

- [ ] **Step 3: Implement the minimal typed configuration**

Use private Codable wire values and public validated values:

~~~swift
struct SupabaseAuthConfiguration: Equatable, Sendable {
    static let supportedSchemaVersion = 1

    let projectURL: URL
    let authURL: URL
    let publishableKey: String
    let redirectURL: URL
    let entitlementURL: URL
    let entitlementIssuer: String
    let entitlementAudience: String
    let publicKeys: [String: Data]

    static func load(data: Data) throws -> Self {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.schemaVersion == supportedSchemaVersion,
              let projectURL = URL(string: wire.projectURL),
              let entitlementURL = URL(string: wire.entitlementURL),
              let redirectURL = URL(string: wire.redirectURL),
              projectURL.scheme == "https",
              projectURL.user == nil,
              projectURL.password == nil,
              projectURL.port == nil,
              projectURL.query == nil,
              projectURL.fragment == nil,
              entitlementURL.scheme == "https",
              entitlementURL.host == projectURL.host,
              entitlementURL.path == "/functions/v1/entitlement",
              redirectURL.scheme == "com.tachouweng.ytdownloaderpro2",
              redirectURL.host == "auth",
              redirectURL.path == "/callback",
              wire.publishableKey.hasPrefix("sb_publishable_"),
              !wire.publishableKey.hasPrefix("sb_secret_"),
              !wire.entitlementIssuer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !wire.entitlementAudience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !wire.publicKeys.isEmpty
        else {
            throw SupabaseAuthConfigurationError.invalid
        }
        // Decode each public key with strict unpadded base64url; reject empty or duplicate kid values.
        return Self(
            projectURL: projectURL,
            authURL: projectURL.appendingPathComponent("auth/v1"),
            publishableKey: wire.publishableKey,
            redirectURL: redirectURL,
            entitlementURL: entitlementURL,
            entitlementIssuer: wire.entitlementIssuer,
            entitlementAudience: wire.entitlementAudience,
            publicKeys: try decodePublicKeys(wire.publicKeys)
        )
    }
}
~~~

Resolve only exact modes:

~~~swift
enum AuthEnvironment: String, Equatable, Hashable, Sendable {
    case disabled
    case mock
    case staging
    case production
}

struct AuthEnvironmentResolution: Equatable, Sendable {
    let environment: AuthEnvironment
    let configuration: SupabaseAuthConfiguration?

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configuration: SupabaseAuthConfiguration?
    ) -> Self {
        switch environment["YTDP_AUTH_MODE"] {
        case "mock":
            return .init(environment: .mock, configuration: nil)
        case "staging" where configuration != nil:
            return .init(environment: .staging, configuration: configuration)
        default:
            return .init(environment: .disabled, configuration: nil)
        }
    }
}
~~~

Do not make production resolvable in this task.

- [ ] **Step 4: Add adversarial cases and make all focused tests pass**

Add table-driven tests for:

- wrong schema;
- missing host;
- port, query, fragment, userinfo, and HTTP;
- entitlement path variations;
- redirect query/fragment;
- empty issuer/audience;
- malformed or empty public-key map;
- service-role/JWT-looking key prefixes;
- unsupported environment values; and
- sanitized error descriptions that do not echo input.

Run:

~~~sh
swift test --filter SupabaseAuthConfigurationTests
swift test --filter AuthenticationModelsTests
~~~

Expected: both suites pass.

- [ ] **Step 5: Commit the configuration boundary**

~~~sh
git add swift-2.0/Package.swift \
  swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationModels.swift \
  swift-2.0/Sources/YTDownloaderPro2/Authentication/SupabaseAuthConfiguration.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/SupabaseAuthConfigurationTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/supabase-staging-configuration.json
git commit -m "feat(swift): add fail-closed Supabase configuration"
~~~

---

### Task 2: Define The Supabase Schema And Pure Grant Contract

**Files:**
- Create: supabase/deno.json
- Create: supabase/migrations/202609230001_account_entitlements.sql
- Create: supabase/functions/entitlement/contract.ts
- Create: supabase/functions/entitlement/contract_test.ts
- Create: tests/test_supabase_contract.py

**Interfaces:**
- Produces: deriveEntitlement(grant, now) -> EntitlementClaimsInput.
- Produces: canonicalFreeEntitlement(now) and canonicalProFeatures.
- Produces: private account_profiles, entitlement_grants, and entitlement_audit_events tables with no client mutation policy.
- Consumes later: Task 3 signs EntitlementClaimsInput and loads one grant by verified user UUID.

- [ ] **Step 1: Write failing static SQL and TypeScript contract tests**

The Python test must assert:

~~~python
def test_entitlement_tables_are_private_and_rls_enabled(self):
    sql = MIGRATION.read_text(encoding="utf-8")
    for table in ("account_profiles", "entitlement_grants", "entitlement_audit_events"):
        self.assertIn(f"create table private.{table}", sql.lower())
        self.assertIn(f"alter table private.{table} enable row level security", sql.lower())
    self.assertNotRegex(sql.lower(), r"create policy .* entitlement_grants .* (insert|update|delete)")

def test_grant_constraints_are_explicit(self):
    sql = MIGRATION.read_text(encoding="utf-8").lower()
    self.assertIn("check (plan in ('free', 'pro'))", sql)
    self.assertIn("check (status in ('none', 'active', 'suspended'))", sql)
    self.assertIn("check (max_video_height is null or max_video_height > 0)", sql)
    self.assertIn("revision bigint not null default 1 check (revision > 0)", sql)
~~~

The Deno test must cover:

~~~typescript
Deno.test("missing or inactive grant derives canonical Free", () => {
  const now = new Date("2026-09-24T00:00:00Z");
  assertEquals(deriveEntitlement(null, now), canonicalFreeEntitlement(now));
  assertEquals(deriveEntitlement(activeGrant({ status: "suspended" }), now).plan, "free");
});

Deno.test("only a consistent in-window Pro grant derives Pro", () => {
  const now = new Date("2026-09-24T00:00:00Z");
  const result = deriveEntitlement(activeGrant(), now);
  assertEquals(result.plan, "pro");
  assertEquals(result.subscriptionState, "active");
  assertEquals(result.maxVideoHeight, null);
  assertEquals(new Set(result.features), new Set(CANONICAL_PRO_FEATURES));
});

Deno.test("grant feature input cannot expand the reviewed Pro matrix", () => {
  const grant = activeGrant({ features: ["download.single", "unknown.super-admin"] });
  assertEquals(deriveEntitlement(grant, new Date("2026-09-24T00:00:00Z")).features, CANONICAL_PRO_FEATURES);
});
~~~

- [ ] **Step 2: Run both suites and witness missing-file failures**

~~~sh
python3 -m unittest tests.test_supabase_contract -v
deno test supabase/functions/entitlement/contract_test.ts
~~~

Expected: Python fails because the migration is missing; Deno fails because contract.ts is missing.

- [ ] **Step 3: Add the constrained SQL migration**

Create the private schema and exact tables described by the spec. Include:

~~~sql
create schema if not exists private;
revoke all on schema private from anon, authenticated;

create table private.entitlement_grants (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null check (plan in ('free', 'pro')),
  status text not null check (status in ('none', 'active', 'suspended')),
  features text[] not null default '{}',
  max_video_height integer null check (max_video_height is null or max_video_height > 0),
  valid_from timestamptz not null,
  valid_until timestamptz null check (valid_until is null or valid_until > valid_from),
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default now()
);

alter table private.entitlement_grants enable row level security;
~~~

Add equivalent exact columns and constraints for account_profiles and entitlement_audit_events. Grant no table privileges and create no authenticated client policies.

- [ ] **Step 4: Implement the pure derivation contract**

Define exact wire types and the reviewed feature lists:

~~~typescript
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
~~~

Free must always use the reviewed Free feature set, 720, none, and revision 0. Pro must use CANONICAL_PRO_FEATURES and null height. Reject malformed dates, non-integer revisions, non-positive limits, and grants outside valid_from/valid_until by deriving Free.

- [ ] **Step 5: Run formatting, lint, and focused tests**

~~~sh
deno fmt --check supabase/functions/entitlement
deno lint supabase/functions/entitlement
deno test supabase/functions/entitlement/contract_test.ts
python3 -m unittest tests.test_supabase_contract -v
~~~

Expected: all pass without network or environment permissions.

- [ ] **Step 6: Commit the backend data contract**

~~~sh
git add supabase/deno.json \
  supabase/migrations/202609230001_account_entitlements.sql \
  supabase/functions/entitlement/contract.ts \
  supabase/functions/entitlement/contract_test.ts \
  tests/test_supabase_contract.py
git commit -m "feat(backend): define entitlement data contract"
~~~

---

### Task 3: Sign And Serve Entitlements In The Edge Function

**Files:**
- Create: supabase/functions/entitlement/jws.ts
- Create: supabase/functions/entitlement/jws_test.ts
- Create: supabase/functions/entitlement/handler.ts
- Create: supabase/functions/entitlement/handler_test.ts
- Create: supabase/functions/entitlement/index.ts
- Create: supabase/functions/entitlement/test-fixtures/es256-public-key.x963
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/entitlement-valid-es256.jws
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/entitlement-es256-public-key.x963
- Modify: supabase/deno.json
- Modify: tests/test_supabase_contract.py

**Interfaces:**
- Consumes: deriveEntitlement(grant, now) from Task 2.
- Produces: createEntitlementHandler(dependencies) -> (Request) => Promise<Response>.
- Produces: signEntitlement(payload, key, kid) -> Promise<string>.
- Produces: a deterministic compact JWS fixture shared with Swift tests.

- [ ] **Step 1: Write failing JWS and handler tests**

Cover exact protected headers, 24-hour claims, identity derivation, no request-selected user/plan, no-store, and safe errors:

~~~typescript
Deno.test("signer emits an ES256 compact JWS with the reviewed header", async () => {
  const keyPair = await generateEphemeralTestKeyPair();
  const token = await signEntitlement(fixedPayload(), keyPair.privateKey, "test-es256-2026-09");
  const [header, payload, signature] = token.split(".");
  assertEquals(decodeJSON(header), { alg: "ES256", kid: "test-es256-2026-09", typ: "JWT" });
  assertEquals(base64URLDecode(signature).byteLength, 64);
  assert(await verifySignature(token, keyPair.publicKey));
  assertEquals(decodeJSON(payload).exp - decodeJSON(payload).iat, 86_400);
});

Deno.test("handler derives subject only from verified bearer authentication", async () => {
  const dependencies = fixtureDependencies({ verifiedUserID: "11111111-1111-1111-1111-111111111111" });
  const response = await createEntitlementHandler(dependencies)(
    request({ body: { schema: 1, platform: "macos", userID: "attacker", plan: "pro" } })
  );
  assertEquals(response.status, 400);
  assertEquals(dependencies.loadedUserIDs, []);
});

Deno.test("handler returns bounded unauthorized without echoing bearer or database errors", async () => {
  const response = await createEntitlementHandler(fixtureDependencies({ authenticationError: new Error("raw-secret") }))(
    request({ authorization: "Bearer sensitive-token" })
  );
  assertEquals(response.status, 401);
  const text = await response.text();
  assertFalse(text.includes("sensitive-token"));
  assertFalse(text.includes("raw-secret"));
});
~~~

- [ ] **Step 2: Run the tests and witness the missing implementation**

~~~sh
deno test supabase/functions/entitlement/jws_test.ts \
  supabase/functions/entitlement/handler_test.ts
~~~

Expected: failure because jws.ts and handler.ts do not exist.

- [ ] **Step 3: Implement strict base64url and ES256 signing**

Use Web Crypto with a PKCS#8 P-256 private key supplied only through runtime dependency injection. Unit tests generate an ephemeral P-256 key pair in memory. The signer must:

- reject an empty kid;
- encode UTF-8 JSON without padding;
- sign exactly ASCII header.payload with ECDSA SHA-256;
- accept only a 64-byte raw R || S signature;
- never log key material or claims; and
- create iat, nbf, exp, and jti from injected clock/UUID sources.

The payload constructor uses:

~~~typescript
{
  iss: dependencies.issuer,
  aud: dependencies.audience,
  sub: verifiedUserID,
  iat: nowSeconds,
  nbf: nowSeconds - 30,
  exp: nowSeconds + 86_400,
  jti: dependencies.randomUUID(),
  schema: 1,
  plan: derived.plan,
  features: derived.features,
  maxVideoHeight: derived.maxVideoHeight,
  subscriptionState: derived.subscriptionState,
  grantRevision: derived.grantRevision
}
~~~

- [ ] **Step 4: Implement the dependency-injected HTTP handler**

Define:

~~~typescript
export type EntitlementDependencies = Readonly<{
  verifyAccessToken(token: string): Promise<string>;
  loadGrant(userID: string): Promise<GrantRow | null>;
  sign(payload: EntitlementPayload): Promise<string>;
  now(): Date;
  randomUUID(): string;
}>;

export function createEntitlementHandler(
  dependencies: EntitlementDependencies
): (request: Request) => Promise<Response>;
~~~

Accept only POST, application/json, and exactly { schema: 1, platform: "macos" }. Reject unknown body keys. Return JSON { token } and headers Content-Type: application/json and Cache-Control: no-store. Use bounded codes method_not_allowed, invalid_request, unauthorized, and service_unavailable plus a random request ID.

- [ ] **Step 5: Add the deploy entry point with pinned dependencies**

In supabase/deno.json:

~~~json
{
  "imports": {
    "@supabase/supabase-js": "npm:@supabase/supabase-js@2.117.0"
  },
  "compilerOptions": {
    "strict": true
  }
}
~~~

index.ts must read SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ENTITLEMENT_ES256_PRIVATE_KEY_PKCS8, ENTITLEMENT_ES256_KID, ENTITLEMENT_ISSUER, and ENTITLEMENT_AUDIENCE at startup, create a server-side Supabase client, verify the bearer with auth.getUser(token), and query private.entitlement_grants for only that verified UUID. Missing configuration must return service_unavailable without naming the missing secret.

- [ ] **Step 6: Generate and cross-check the fixed public fixture without committing a private key**

Use a one-shot fixture generator that creates a P-256 key pair in memory, writes only the public X9.63 representation and signed compact JWS, then exits without writing or printing the private key. Create entitlement-valid-es256.jws with:

- subject 11111111-1111-1111-1111-111111111111;
- issuer https://accounts.ytdownloaderpro.example/staging;
- audience com.tachouweng.ytdownloaderpro2;
- iat 1_790_208_000;
- nbf 1_790_207_970;
- exp 1_790_294_400;
- jti 22222222-2222-2222-2222-222222222222;
- Pro canonical features; and
- grantRevision 7.

Copy the public key to both test-fixture locations and add a Deno test that verifies the committed JWS signature with that public key, decodes the exact expected header and payload, and proves the fixture contains no private-key bytes. The Swift verifier test consumes the same JWS and public key. Never commit, log, or persist the private key used to produce this fixture.

- [ ] **Step 7: Run all backend tests**

~~~sh
deno fmt --check supabase/functions/entitlement
deno lint supabase/functions/entitlement
deno test supabase/functions/entitlement
python3 -m unittest tests.test_supabase_contract -v
~~~

Expected: all pass. No cloud project or network is used.

- [ ] **Step 8: Commit the signed endpoint**

~~~sh
git add supabase/functions/entitlement supabase/deno.json \
  swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/entitlement-valid-es256.jws \
  swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/entitlement-es256-public-key.x963 \
  tests/test_supabase_contract.py
git commit -m "feat(backend): issue signed entitlement tokens"
~~~

---

### Task 4: Verify And Cache Entitlements In Swift

**Files:**
- Create: swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementToken.swift
- Create: swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementVerifier.swift
- Create: swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementVault.swift
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/EntitlementVerifierTests.swift
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/EntitlementVaultTests.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementSnapshot.swift
- Modify: swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/AuthenticationFixtures.swift

**Interfaces:**
- Produces: EntitlementVerifying.verify(token:context:) throws -> VerifiedEntitlement.
- Produces: EntitlementVault load/save/delete for one verified token per environment.
- Produces: VerifiedEntitlement.use(at:allowOfflineGrace:) and EntitlementUse current/offlineGrace/expired.
- Consumes: public key ring and issuer/audience from Task 1 and the shared JWS fixture from Task 3.

- [ ] **Step 1: Write failing cross-runtime verifier tests**

Define the intended interface in tests:

~~~swift
func testDenoFixtureVerifiesToExactProSnapshot() throws {
    let verified = try EntitlementVerifier().verify(
        token: fixtureJWS(),
        context: fixtureContext(
            subject: "11111111-1111-1111-1111-111111111111",
            now: Date(timeIntervalSince1970: 1_790_208_100)
        )
    )
    XCTAssertEqual(verified.grantRevision, 7)
    XCTAssertEqual(verified.snapshot, .syntheticPro)
    XCTAssertEqual(verified.use(at: verified.expiresAt.addingTimeInterval(-1), allowOfflineGrace: false), .current)
    XCTAssertEqual(verified.use(at: verified.expiresAt, allowOfflineGrace: false), .expired)
    XCTAssertEqual(verified.use(at: verified.expiresAt, allowOfflineGrace: true), .offlineGrace)
    XCTAssertEqual(verified.use(at: verified.expiresAt.addingTimeInterval(72 * 60 * 60), allowOfflineGrace: true), .offlineGrace)
    XCTAssertEqual(verified.use(at: verified.expiresAt.addingTimeInterval(72 * 60 * 60 + 1), allowOfflineGrace: true), .expired)
}

func testVerifierRejectsCrossAccountAndEveryTrustBoundary() {
    for mutation in mutationsOfValidFixture([
        .algorithm("none"), .unknownKey, .invalidSignature, .issuer, .audience,
        .subject, .notBefore, .expiredBeyondSkew, .schema, .planFeatureMismatch,
        .invalidHeight, .invalidRevision, .paddedBase64URL, .extraSegment
    ]) {
        XCTAssertThrowsError(try EntitlementVerifier().verify(token: mutation.token, context: mutation.context))
    }
}
~~~

Add five-minute accepted clock-skew tests for JWS claim validation and prove Free never receives offline Pro grace. Keep business expiry strict: `current` is only `now < exp`; the verification skew must not silently extend the normal Pro lifetime.

- [ ] **Step 2: Run and witness missing-type failures**

~~~sh
cd swift-2.0
swift test --filter EntitlementVerifierTests
swift test --filter EntitlementVaultTests
~~~

Expected: compilation fails because verifier, verified token, use policy, and vault types do not exist.

- [ ] **Step 3: Implement strict compact JWS parsing and CryptoKit verification**

Use:

~~~swift
struct EntitlementVerificationContext: Sendable {
    let issuer: String
    let audience: String
    let subject: String
    let now: Date
    let allowedClockSkew: TimeInterval
    let publicKeys: [String: P256.Signing.PublicKey]
}

struct VerifiedEntitlement: Equatable, Sendable {
    let compactToken: String
    let subject: String
    let grantRevision: Int64
    let issuedAt: Date
    let expiresAt: Date
    let snapshot: EntitlementSnapshot

    func use(at date: Date) -> EntitlementUse
}
~~~

Split into exactly three non-empty segments, reject padding and non-canonical base64url, decode header/claims into typed structs, require alg ES256 and known kid, and verify:

~~~swift
let signingInput = Data((segments[0] + "." + segments[1]).utf8)
let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
guard publicKey.isValidSignature(signature, for: signingInput) else {
    throw EntitlementVerificationError.invalidSignature
}
~~~

Then validate issuer, audience, subject, iat, nbf, exp, schema, plan/state/features/height consistency, and positive revision before constructing EntitlementSnapshot.

- [ ] **Step 4: Implement the scoped entitlement vault**

Define:

~~~swift
protocol EntitlementVault: Sendable {
    func load(environment: AuthEnvironment) async throws -> String?
    func save(_ verifiedCompactToken: String, environment: AuthEnvironment) async throws
    func delete(environment: AuthEnvironment) async throws
}
~~~

Implement InMemoryEntitlementVault and KeychainEntitlementVault using:

- service com.catstayathome.YTDownloaderPro.entitlement.<environment>;
- account verified-token;
- kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
- kSecAttrSynchronizable false; and
- kSecUseDataProtectionKeychain true.

Only EntitlementVerifier output may be passed to save. Missing delete is success. Malformed load is a typed failure; never return unverified bytes.

- [ ] **Step 5: Add cache and stale-revision tests**

Test one record per environment, isolation from CredentialVault, delete idempotence, malformed record failure, and:

~~~swift
func testLowerRevisionCannotReplaceVerifiedTokenForSameSubject() async throws {
    let store = VerifiedEntitlementStore(vault: InMemoryEntitlementVault())
    try await store.adopt(revisionSeven, environment: .staging)
    try await store.adopt(revisionSix, environment: .staging)
    XCTAssertEqual(try await store.load(environment: .staging)?.grantRevision, 7)
}
~~~

If the implementation introduces VerifiedEntitlementStore, keep it in EntitlementVault.swift and accept only already verified values.

- [ ] **Step 6: Run focused and strict tests**

~~~sh
swift test --filter EntitlementVerifierTests
swift test --filter EntitlementVaultTests
swift test --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
~~~

Expected: focused and full public suites pass.

- [ ] **Step 7: Commit verification and cache**

~~~sh
git add swift-2.0/Sources/YTDownloaderPro2/Entitlements \
  swift-2.0/Tests/YTDownloaderPro2Tests/EntitlementVerifierTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/EntitlementVaultTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/AuthenticationFixtures.swift
git commit -m "feat(swift): verify and cache entitlements"
~~~

---

### Task 5: Fetch Entitlements And Drive The Existing Feature Policy

**Files:**
- Create: swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementClient.swift
- Create: swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementController.swift
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/EntitlementClientTests.swift
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/EntitlementControllerTests.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Entitlements/AppPlan.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Entitlements/PlanController.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Entitlements/PlanProvider.swift
- Modify: swift-2.0/Tests/YTDownloaderPro2Tests/PlanControllerTests.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift

**Interfaces:**
- Consumes: verified-token and vault contracts from Task 4.
- Produces: EntitlementClient.fetch(accessToken:) async throws -> String.
- Produces: EntitlementController restore, refresh, and clear operations.
- Produces: PlanController.applyVerifiedEntitlement(_:) and clearVerifiedEntitlement().
- Consumes later: Task 7 bridges authenticated account state into EntitlementController.

- [ ] **Step 1: Write failing privacy and HTTP-contract tests**

~~~swift
func testClientSendsOnlyReviewedBodyAndBearerHeader() async throws {
    let transport = RecordingEntitlementTransport(response: .success(tokenResponse()))
    let client = EntitlementClient(endpoint: fixtureURL, transport: transport)
    _ = try await client.fetch(accessToken: "memory-only-access")
    let request = try XCTUnwrap(await transport.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer memory-only-access")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: request.httpBody!) as? NSDictionary
    )
    XCTAssertEqual(body, [
        "schema": 1, "platform": "macos"
    ] as NSDictionary)
    XCTAssertFalse(String(data: request.httpBody!, encoding: .utf8)!.contains("url"))
}

func testUnauthorizedRefreshesAuthenticationAtMostOnce() async {
    let auth = RefreshProbe(tokens: ["old", "new"])
    let transport = SequenceTransport([.unauthorized, .unauthorized])
    await controller.refresh(using: auth)
    XCTAssertEqual(await auth.refreshCount, 1)
    XCTAssertEqual(transport.requestCount, 2)
}
~~~

Also test non-2xx bounded errors, oversized body rejection, invalid JSON, missing token, cancellation, no response-body leakage, and no automatic retry for 400/403/500.

- [ ] **Step 2: Run and witness failures**

~~~sh
swift test --filter EntitlementClientTests
swift test --filter EntitlementControllerTests
~~~

Expected: compilation fails because client/controller types do not exist.

- [ ] **Step 3: Implement the app-owned transport and client**

~~~swift
protocol EntitlementTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct EntitlementClient: Sendable {
    func fetch(accessToken: String) async throws -> String
}
~~~

Require a non-empty token, build the fixed JSON body, set a 20-second timeout, accept only 200 with at most 64 KiB, and decode exactly one non-empty token. Map 401 separately so the controller can refresh once. Error values contain bounded categories only.

- [ ] **Step 4: Add a real server plan without weakening the internal override**

Change:

~~~swift
enum AppPlan: String, Codable, Equatable, Sendable {
    case free
    case pro
    case testPro = "test-pro"
}
~~~

InternalTestPlanStore must accept only free and test-pro from UserDefaults; it must reject pro. PlanController stores a verified server snapshot separately. Its effective priority is:

~~~swift
if internalOverride == .testPro {
    return (.testPro, .syntheticPro)
}
if let serverSnapshot, serverSnapshot.plan == .pro {
    return (.pro, serverSnapshot)
}
return (.free, .syntheticFree)
~~~

applyVerifiedEntitlement publishes only after verification. clearVerifiedEntitlement returns to Free unless Test Pro is selected. Keep currentPlan publication so DownloadStore reconciliation continues to run.

- [ ] **Step 5: Implement EntitlementController**

Use:

~~~swift
@MainActor
final class EntitlementController: ObservableObject {
    @Published private(set) var status: EntitlementStatus

    func restore(subject: String) async
    func refresh(accessToken: String, subject: String) async
    func clear() async
}
~~~

restore loads, verifies, checks subject, applies current/grace token, or deletes malformed/cross-account cache and applies Free. refresh fetches, verifies, rejects lower revision, persists, and then applies. A stale operation ID cannot adopt after clear or a newer subject. clear invalidates operations, clears cache, and tells PlanController to clear server entitlement.

- [ ] **Step 6: Pin the review-focus regressions**

Add tests proving:

- a response for account A cannot apply after account B starts;
- revision 6 cannot replace revision 7;
- a verified Free or suspended token downgrades immediately;
- active DownloadRunner work is not cancelled;
- queued/retry/new Pro work becomes restricted through existing reconciliation;
- exact current/grace/expired clock boundaries;
- malformed cache is deleted without deleting auth credentials or jobs; and
- network failure preserves a separately valid cached grant but otherwise uses Free.

- [ ] **Step 7: Run focused, store, runner, and strict suites**

~~~sh
swift test --filter EntitlementClientTests
swift test --filter EntitlementControllerTests
swift test --filter PlanControllerTests
swift test --filter DownloadStoreTests
swift test --filter DownloadRunnerTests
swift test --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
~~~

Expected: all pass.

- [ ] **Step 8: Commit client and policy integration**

~~~sh
git add swift-2.0/Sources/YTDownloaderPro2/Entitlements \
  swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/EntitlementClientTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/EntitlementControllerTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/PlanControllerTests.swift
git commit -m "feat(swift): apply verified server entitlements"
~~~

---

### Task 6: Add Supabase Google PKCE Behind AuthenticationProvider

**Files:**
- Create: swift-2.0/Sources/YTDownloaderPro2/Authentication/EphemeralSupabaseAuthStorage.swift
- Create: swift-2.0/Sources/YTDownloaderPro2/Authentication/SupabaseGoogleAuthenticationProvider.swift
- Create: swift-2.0/Sources/YTDownloaderPro2/Authentication/SupabaseSessionMapper.swift
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/EphemeralSupabaseAuthStorageTests.swift
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/SupabaseGoogleAuthenticationProviderTests.swift
- Modify: swift-2.0/Package.swift
- Create: swift-2.0/Package.resolved
- Modify: swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationModels.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationProvider.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Authentication/AccountSessionStore.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Authentication/MockAuthenticationProvider.swift
- Modify: swift-2.0/Tests/YTDownloaderPro2Tests/AccountSessionStoreTests.swift
- Modify: swift-2.0/Tests/YTDownloaderPro2Tests/MockAuthenticationProviderTests.swift

**Interfaces:**
- Consumes: validated SupabaseAuthConfiguration from Task 1.
- Produces: SupabaseGoogleAuthenticationProvider implementing AuthenticationProvider.
- Produces: AccountSessionStore.authenticatedContext() and refreshAuthenticatedSession().
- Produces: AuthenticatedSessionContext with accountID, accessToken, and expiry.
- Consumes later: Task 7 observes the account store and drives EntitlementController.

- [ ] **Step 1: Add the exact Auth dependency and resolve it**

Modify Package.swift:

~~~swift
dependencies: [
    .package(
        url: "https://github.com/supabase/supabase-swift.git",
        exact: "2.55.2"
    )
],
targets: [
    .executableTarget(
        name: "YTDownloaderPro2",
        dependencies: [
            .product(name: "Auth", package: "supabase-swift")
        ],
        resources: [.process("Resources")]
    )
]
~~~

Run:

~~~sh
cd swift-2.0
swift package resolve
swift package show-dependencies
~~~

Expected: Package.resolved pins supabase-swift 2.55.2. Review transitive dependencies and licenses before continuing; do not accept a floating branch or prerelease.

- [ ] **Step 2: Write failing memory-only storage tests**

~~~swift
func testEphemeralStorageNeverTouchesCredentialVaultAndReturnsNilWhenAbsent() throws {
    let storage = EphemeralSupabaseAuthStorage()
    XCTAssertNil(try storage.retrieve(key: "session"))
    try storage.store(key: "session", value: Data("temporary".utf8))
    XCTAssertEqual(try storage.retrieve(key: "session"), Data("temporary".utf8))
    try storage.remove(key: "session")
    XCTAssertNil(try storage.retrieve(key: "session"))
}

func testNewStorageInstanceCannotRestorePriorProcessState() throws {
    let first = EphemeralSupabaseAuthStorage()
    try first.store(key: "session", value: Data("temporary".utf8))
    XCTAssertNil(try EphemeralSupabaseAuthStorage().retrieve(key: "session"))
}
~~~

Use NSLock or another strict-concurrency-safe primitive because AuthLocalStorage methods are synchronous.

- [ ] **Step 3: Run and witness failure, then implement storage**

~~~sh
swift test --filter EphemeralSupabaseAuthStorageTests
~~~

Expected RED: type missing.

Implement AuthLocalStorage with store, retrieve, and idempotent remove. It keeps [String: Data] in memory only and exposes no enumeration or logging.

- [ ] **Step 4: Separate identity from entitlement in authentication models**

Remove MockPlanPreview and AccountSummary.planPreview. Add:

~~~swift
struct AccountSummary: Codable, Equatable, Sendable {
    let provider: AuthenticationProviderKind
    let accountID: String
    let displayName: String
    let maskedEmail: String?
    let expiresAt: Date
}

struct AuthenticatedSessionContext: Equatable, Sendable {
    let accountID: String
    let accessToken: String
    let expiresAt: Date
}
~~~

Old stored JSON may contain planPreview; JSONDecoder ignores that unknown field. maskedEmail is optional so old envelopes remain decodable. MockAuthenticationProvider continues to create identity-only synthetic sessions.

- [ ] **Step 5: Write failing provider and mapper tests before production code**

Test the app-owned mapper separately from SDK values:

~~~swift
func testMapperUsesImmutableUserUUIDAndMasksEmail() throws {
    let session = try SupabaseSessionMapper.map(
        .init(
            userID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            email: "person@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: 1_790_208_000
        )
    )
    XCTAssertEqual(session.summary.accountID, "11111111-1111-1111-1111-111111111111")
    XCTAssertEqual(session.summary.maskedEmail, "p•••••@example.com")
    XCTAssertEqual(session.summary.provider, .google)
}
~~~

Provider tests inject a SupabaseAuthServicing protocol and assert:

- signIn asks only for Google, exact redirect, and openid email profile;
- cancellation maps to AuthenticationProviderError.cancelled;
- refresh uses the envelope refreshCredential and adopts its rotated replacement;
- mismatched user UUID on refresh is invalidSession;
- signOut passes the current refresh credential and does not throw raw SDK errors; and
- no returned or thrown value contains OAuth URL, code, state, nonce, or provider body.

- [ ] **Step 6: Run provider tests and witness missing implementation**

~~~sh
swift test --filter SupabaseGoogleAuthenticationProviderTests
swift test --filter AccountSessionStoreTests
~~~

Expected RED: provider/mapper/service types and new AccountSummary shape are missing.

- [ ] **Step 7: Implement the AuthClient adapter**

Construct AuthClient with:

~~~swift
AuthClient(
    url: configuration.authURL,
    headers: [
        "apikey": configuration.publishableKey,
        "Authorization": "Bearer " + configuration.publishableKey
    ],
    flowType: .pkce,
    redirectToURL: configuration.redirectURL,
    localStorage: EphemeralSupabaseAuthStorage(),
    autoRefreshToken: false
)
~~~

The adapter calls signInWithOAuth for Google using ASWebAuthenticationSession and scopes openid email profile, refreshSession(refreshToken:) for restore/rotation, and local-scope sign-out where supported by the pinned SDK. Map SDK errors immediately to app-owned typed errors; never expose AuthError descriptions to UI or diagnostics.

- [ ] **Step 8: Extend AccountSessionStore without weakening serialization**

Add:

~~~swift
func authenticatedContext() -> AuthenticatedSessionContext?
func refreshAuthenticatedSession() async throws -> AuthenticatedSessionContext
~~~

authenticatedContext returns nil unless currentSummary, accessToken, and matching account state exist. refreshAuthenticatedSession participates in the same operation ownership used by sign-in/restore/sign-out, calls provider.restore with the current envelope, validates same account/provider, saves the rotated credential, then publishes the new summary/context. A stale refresh cannot overwrite a newer sign-in or logout.

Update live construction:

- mock registers only mock providers;
- staging requires validated configuration and registers Google only;
- disabled registers none;
- production remains disabled.

- [ ] **Step 9: Run focused and strict tests**

~~~sh
swift test --filter EphemeralSupabaseAuthStorageTests
swift test --filter SupabaseGoogleAuthenticationProviderTests
swift test --filter AccountSessionStoreTests
swift test --filter MockAuthenticationProviderTests
swift test --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
~~~

Expected: all pass, including existing cancellation and Keychain commit-boundary tests.

- [ ] **Step 10: Commit real authentication behind the provider boundary**

~~~sh
git add swift-2.0/Package.swift swift-2.0/Package.resolved \
  swift-2.0/Sources/YTDownloaderPro2/Authentication \
  swift-2.0/Tests/YTDownloaderPro2Tests/EphemeralSupabaseAuthStorageTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/SupabaseGoogleAuthenticationProviderTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/AccountSessionStoreTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/MockAuthenticationProviderTests.swift
git commit -m "feat(swift): add Supabase Google PKCE provider"
~~~

---

### Task 7: Connect Account, Entitlement, Plan, And Localized UI

**Files:**
- Create: swift-2.0/Sources/YTDownloaderPro2/Entitlements/AccountEntitlementBridge.swift
- Create: swift-2.0/Tests/YTDownloaderPro2Tests/AccountEntitlementBridgeTests.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Views/AccountPresentation.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Views/AccountSettingsSection.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Views/AccountSidebarView.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Views/PlanPresentation.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift
- Modify: swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings
- Modify: swift-2.0/Tests/YTDownloaderPro2Tests/AccountPresentationTests.swift
- Modify: swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift
- Modify: swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift
- Modify: swift-2.0/Tests/YTDownloaderPro2Tests/PlanPresentationTests.swift

**Interfaces:**
- Consumes: AccountSessionStore authenticated context and EntitlementController from Tasks 5-6.
- Produces: AccountEntitlementBridge.start() and stop() lifecycle.
- Produces: real Free/Pro/offline presentation with Google-only staging controls.
- Preserves: internal Test Pro selector only in YTDP_INTERNAL_TEST.

- [ ] **Step 1: Write failing bridge race and lifecycle tests**

~~~swift
func testSignedInStateRefreshesEntitlementForMatchingAccount() async {
    let fixture = BridgeFixture()
    fixture.account.publishSignedIn(accountA)
    await fixture.drain()
    XCTAssertEqual(fixture.entitlement.refreshes, [accountA.context])
}

func testLogoutClearsBeforeLateRefreshCanAdopt() async {
    let fixture = BridgeFixture(suspendedRefresh: true)
    fixture.account.publishSignedIn(accountA)
    fixture.account.publishSigningOut()
    fixture.entitlement.completeSuspendedRefresh(with: proForAccountA)
    await fixture.drain()
    XCTAssertEqual(fixture.plan.currentPlan, .free)
    XCTAssertEqual(fixture.entitlement.clearCount, 1)
}

func testReauthenticationPreservesStillValidCachedEntitlementButAccountChangeDoesNot() async {
    let fixture = BridgeFixture(
        initialSubject: accountA.summary.accountID,
        cachedEntitlement: proForAccountA
    )
    fixture.account.publishRequiresReauthentication(accountA.summary)
    await fixture.drain()
    XCTAssertEqual(fixture.entitlement.clearCount, 0)
    XCTAssertEqual(fixture.plan.currentPlan, .pro)

    fixture.account.publishSignedIn(accountB)
    await fixture.drain()
    XCTAssertEqual(fixture.entitlement.clearCount, 1)
    XCTAssertEqual(fixture.entitlement.refreshes.last, accountB.context)
}
~~~

- [ ] **Step 2: Run and witness failure**

~~~sh
swift test --filter AccountEntitlementBridgeTests
~~~

Expected: bridge type missing.

- [ ] **Step 3: Implement the MainActor bridge**

The bridge subscribes to AccountSessionStore.$state and serializes reactions:

- signedIn with a new account: clear prior subject, restore cached token, then refresh with current access token;
- signedIn with same account and new expiry/token: refresh;
- signingOut or signedOut after a known account: clear immediately;
- requiresReauthentication for the same account: retain independently valid cached token;
- failed auth without an adopted account: remain Free; and
- stop: cancel observation and invalidate pending tasks.

Use operation IDs so late async results cannot cross account transitions. Keep the bridge alive as an AppLifecycle property.

- [ ] **Step 4: Write failing presentation and localization tests**

Assert:

- disabled hides account UI;
- mock shows Google and Apple labels only as existing internal fixtures;
- staging signed-out shows Google only;
- signed-in display reads the effective PlanController plan, not AccountSummary;
- AppPlan.pro localizes as Pro and AppPlan.testPro localizes as Test Pro;
- offline grace and last refresh text are bounded and localized;
- raw Supabase/Auth/JWT strings never appear;
- every new key has en, ja, and zh-Hant values; and
- public compilation has no Test Pro selector.

- [ ] **Step 5: Update presentation and views**

Change presentation constructors to consume effective plan and EntitlementStatus:

~~~swift
static func make(
    environment: AuthEnvironment,
    state: AccountSessionState,
    plan: AppPlan,
    entitlementStatus: EntitlementStatus,
    locale: Locale
) -> Self
~~~

Staging offers Google only. Mock retains both synthetic provider buttons. Settings show:

- current Free, Pro, or Test Pro;
- Free works without login;
- Google account display and optional masked email;
- entitlement refreshing, last verified, or offline grace;
- explicit refresh and logout;
- local non-payment plan introduction for Free; and
- development disclaimer for mock/Test Pro.

Do not display a purchase action or imply Pro can be bought.

- [ ] **Step 6: Wire AppLifecycle**

AppLifecycle creates one validated configuration loader, AccountSessionStore, EntitlementController, PlanController, and AccountEntitlementBridge. Launch order:

1. construct controllers;
2. start bridge;
3. restore authentication;
4. bridge restores/refreshes entitlement after session adoption; and
5. update checking remains independent.

Inject EntitlementController as an environment object only where UI needs status. Downloads continue to depend on PlanController, not the network controller.

- [ ] **Step 7: Run focused, internal-channel, and strict suites**

~~~sh
swift test --filter AccountEntitlementBridgeTests
swift test --filter AccountPresentationTests
swift test --filter PlanPresentationTests
swift test --filter LocalizationTests
swift test --filter DownloadCenterViewTests
swift test --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache-internal-auth" \
  swift test --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors \
  -Xswiftc -DYTDP_INTERNAL_TEST
~~~

Expected: public and internal suites pass; the public build has no internal switch.

- [ ] **Step 8: Commit the integrated account experience**

~~~sh
git add swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift \
  swift-2.0/Sources/YTDownloaderPro2/Entitlements/AccountEntitlementBridge.swift \
  swift-2.0/Sources/YTDownloaderPro2/Views \
  swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift \
  swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings \
  swift-2.0/Tests/YTDownloaderPro2Tests/AccountEntitlementBridgeTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/AccountPresentationTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/PlanPresentationTests.swift
git commit -m "feat(swift): connect accounts to verified plans"
~~~

---

### Task 8: Harden Packaging, Documentation, And Final Verification

**Files:**
- Create: docs/swift-2.0/SUPABASE_STAGING.md
- Create: docs/swift-2.0/ENTITLEMENT_KEY_ROTATION.md
- Create: scripts/check_supabase_configuration.py
- Create: tests/test_supabase_configuration.py
- Modify: scripts/build_swift_2.sh
- Modify: scripts/check_swift_bundle.py
- Modify: tests/test_swift_bundle.py
- Modify: docs/swift-2.0/AUTHENTICATION.md
- Modify: docs/swift-2.0/ENTITLEMENT_ARCHITECTURE.md
- Modify: docs/swift-2.0/DEVELOPMENT.md
- Modify: docs/swift-2.0/RELEASE.md
- Modify: docs/swift-2.0/SBOM_AND_LICENSES.md
- Modify: COMMERCIAL_FEASIBILITY.md
- Modify: PRIVACY_DATA_MAP.md
- Modify: PRIVACY_THREAT_MODEL.md

**Interfaces:**
- Consumes: complete Swift and Supabase implementation.
- Produces: --auth-config packaging gate for internal-test staging builds.
- Produces: bundle verification proving public Free bundles contain no staging config, secret, or internal switch.
- Produces: exact handoff and external staging checklist.

- [ ] **Step 1: Write failing packaging and secret-scanner tests**

Add tests proving:

~~~python
def test_public_build_rejects_auth_config(self):
    result = run_build("--app-channel", "public", "--auth-config", fixture)
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("--auth-config is limited to internal-test staging builds", result.stderr)

def test_internal_staging_config_accepts_publishable_material_only(self):
    result = run_checker(valid_fixture)
    self.assertEqual(result.returncode, 0)

def test_scanner_rejects_service_role_private_key_and_jwt_secret(self):
    for field, value in {
        "serviceRoleKey": "service-role-secret",
        "privateKey": "-----BEGIN PRIVATE KEY-----",
        "publishableKey": "sb_secret_forbidden"
    }.items():
        self.assertNotEqual(run_checker(mutate(field, value)).returncode, 0)

def test_public_bundle_contains_no_supabase_configuration(self):
    bundle = self.fake_bundle(channel="public")
    self.assertBundlePasses(bundle)
    self.assertFalse((bundle / "Contents/Resources/SupabaseConfiguration.json").exists())
~~~

Also test symlinks, world-writable config, malformed JSON, unapproved host, private-key PEM anywhere in Resources, and report redaction.

- [ ] **Step 2: Run and witness failures**

~~~sh
python3 -m unittest tests.test_supabase_configuration tests.test_swift_bundle -v
~~~

Expected: missing checker and unsupported --auth-config behavior.

- [ ] **Step 3: Implement the packaging gate**

Add --auth-config PATH to build_swift_2.sh with these rules:

- accepted only for internal-test;
- regular non-symlink file;
- validated by check_supabase_configuration.py before build;
- copied mode 0644 to Contents/Resources/SupabaseConfiguration.json;
- omitted entirely when not supplied; and
- never printed or included in the JSON report body.

The checker validates the same URL/key/public-key contract as Swift and scans all app resources for forbidden field names, sb_secret_, service-role, BEGIN PRIVATE KEY, Google client secret, HashKey, and HashIV patterns. The bundle verifier rejects config in public builds and verifies exact metadata in internal staging builds.

- [ ] **Step 4: Update documentation with exact local commands**

SUPABASE_STAGING.md must document:

- current local-only status;
- config schema and non-secret fields;
- owner-controlled Supabase/Google setup steps;
- exact redirect com.tachouweng.ytdownloaderpro2://auth/callback;
- Google scopes openid email profile;
- Edge Function secret names without values;
- migration/deploy commands as future manual commands;
- staging test account procedure;
- cleanup and project pause behavior; and
- explicit prohibition on production/billing use.

ENTITLEMENT_KEY_ROTATION.md must document:

1. generate P-256 key offline;
2. add new public kid to app;
3. ship and verify the app;
4. add private key to staging secret storage;
5. switch signing kid;
6. retain old public key for 96 hours, covering 24-hour token plus 72-hour grace;
7. stop signing old kid;
8. remove old public key only after evidence shows no accepted tokens; and
9. incident response for suspected private-key compromise.

Update authentication/entitlement docs to mark the local mock as preserved and this implementation as staging-only. Update privacy documents with Supabase user UUID, optional masked email, refresh credential, signed entitlement, retention, deletion, and vendor-review boundaries. Do not change No-Go paid-launch status.

- [ ] **Step 5: Run every automated gate**

~~~sh
git diff --check
deno fmt --check supabase/functions/entitlement
deno lint supabase/functions/entitlement
deno test supabase/functions/entitlement
python3 -m unittest tests.test_supabase_contract \
  tests.test_supabase_configuration \
  tests.test_swift_bundle -v
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache-final-public" \
  swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache-final-internal" \
  swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors \
  -Xswiftc -DYTDP_INTERNAL_TEST
~~~

Expected: every available gate passes. Record the exact test counts.

- [ ] **Step 6: Build and inspect accountless public and configured internal bundles**

Build public Free without configuration:

~~~sh
./scripts/build_swift_2.sh \
  --app-channel public \
  --version 2.0.1 \
  --architectures arm64 \
  --unsigned-test \
  --sbom-created 2026-09-24T00:00:00Z
~~~

Expected: public bundle contains no SupabaseConfiguration.json and starts Free with no account UI.

Build internal staging only after a local fixture config is supplied:

~~~sh
./scripts/build_swift_2.sh \
  --app-channel internal-test \
  --version 2.0.1 \
  --architectures arm64 \
  --unsigned-test \
  --auth-config swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/supabase-staging-configuration.json \
  --sbom-created 2026-09-24T00:00:00Z
~~~

Expected: bundle verification passes, Test Pro controls remain internal, and no private secret is present. Because ad-hoc builds cannot prove the data-protection Keychain contract, do not claim persistent real login from this artifact.

- [ ] **Step 7: Record unavailable external verification honestly**

Supabase CLI and Docker are currently absent. Do not install them automatically. Record these as blocked external gates until the owner approves installation:

- supabase db reset against a disposable local stack;
- migration/RLS integration tests;
- staging project creation and region review;
- Google OAuth branding and redirect registration;
- Edge Function secret provisioning and deployment;
- real system-browser Google sign-in;
- provisioned Developer ID Keychain persistence; and
- production configuration, users, payment, and release.

Passing local tests does not waive these gates.

- [ ] **Step 8: Commit documentation and packaging hardening**

~~~sh
git add docs/swift-2.0 scripts/build_swift_2.sh \
  scripts/check_swift_bundle.py scripts/check_supabase_configuration.py \
  tests/test_swift_bundle.py tests/test_supabase_configuration.py \
  COMMERCIAL_FEASIBILITY.md PRIVACY_DATA_MAP.md PRIVACY_THREAT_MODEL.md
git commit -m "docs(swift): harden Supabase staging workflow"
~~~

- [ ] **Step 9: Perform final review before integration**

Run:

~~~sh
git status --short
git log --oneline codex/public-macos-2.0.1..HEAD
git diff --check codex/public-macos-2.0.1...HEAD
git diff --stat codex/public-macos-2.0.1...HEAD
~~~

Review specifically:

- no secrets or real account identifiers;
- no production/payment path;
- no account-to-media linkage;
- no public internal plan switch;
- no stale-response race;
- no access token at rest;
- no entitlement acceptance before signature and claim verification;
- no feature enforcement limited to UI only; and
- no unrelated release artifacts or AppIcon changes.

Only after a clean review should the owner choose local merge, PR, or keeping the branch.
