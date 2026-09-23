# Supabase Google Authentication And Entitlement Design

## Document Control

| Field | Value |
| --- | --- |
| Status | Draft for owner review |
| Product | YT Downloader Pro macOS Swift 2.x |
| Prepared | 2026-09-23 |
| Owner | Ta-Chou Weng |
| Backend choice | Supabase Free during development |
| Client integration | Supabase Auth Swift module plus app-owned entitlement client |

This design turns the existing local authentication and Free/Test Pro skeleton
into a development and staging implementation. It does not enable checkout,
recurring billing, public paid availability, or production collection of real
user data. Those actions remain blocked by the commercial, legal, accounting,
provider, privacy, licensing, signing, and owner approval gates already recorded
in the repository.

## 1. Purpose And Success Criteria

The first deliverable proves that the macOS app can:

1. remain fully usable as Free without an account or backend request;
2. use the macOS system browser for Google sign-in through Supabase Auth with
   Authorization Code and PKCE;
3. restore and revoke a Supabase session without exposing credentials to views,
   logs, diagnostics, support reports, exports, or download state;
4. call one authenticated Supabase Edge Function that derives an entitlement
   from server-owned data;
5. verify a signed entitlement locally before applying Pro behavior;
6. preserve a bounded offline grant and otherwise fail closed to Free;
7. feed the verified result into the existing `PlanController`,
   `FeaturePolicy`, `DownloadStore`, and `DownloadRunner` enforcement path; and
8. keep every request independent of media URLs, titles, cookies, local paths,
   download history, thumbnails, and diagnostics.

Success means deterministic local tests and a staging walkthrough demonstrate
Google sign-in, Free, Test Pro, refresh, logout, cancellation, invalid tokens,
expiry, offline grace, and safe fallback. It does not mean the product is ready
to sell or publicly release.

## 2. Scope

### Included

- Supabase development structure, SQL migrations, Row Level Security, and a
  single entitlement Edge Function.
- The official Supabase Swift `Auth` product only, pinned to a reviewed exact
  version through `Package.resolved`.
- Google OAuth through `ASWebAuthenticationSession` with PKCE.
- Existing data-protection Keychain storage through an app-owned adapter.
- Access token in memory and rotating refresh credential in Keychain.
- App-owned HTTP transport for the entitlement endpoint.
- ES256 compact JWS verification with a pinned public-key set.
- Free fallback and a 72-hour offline grace for a previously verified Pro
  entitlement whose normal 24-hour lifetime has expired.
- Internal-test-only fixtures for exercising Free and Pro.
- Traditional Chinese, Japanese, and English account and entitlement states.
- Architecture, setup, testing, rotation, and troubleshooting documentation.

### Excluded

- ECPay, checkout, prices, orders, recurring authorization, cancellation,
  refund, dispute, and webhook implementation.
- Apple sign-in, email magic-link recovery, account linking, account deletion,
  cloud history synchronization, support-ticket submission, and admin UI.
- Production Supabase or Google project creation by the agent.
- Production secrets, production users, public launch, marketing, or billing.
- Direct database access from the app for plan mutation.
- Media, cookie, path, history, thumbnail, or diagnostic upload.

## 3. Selected Integration Strategy

The app imports the official Supabase Swift `Auth` product, not the complete
`Supabase` product. The SDK owns OAuth URL construction, PKCE exchange, provider
callback handling, token refresh, and provider logout. The app retains ownership
of presentation state, credential storage policy, entitlement networking,
signature verification, feature policy, and diagnostics.

This boundary provides reviewed OAuth behavior without coupling downloads,
entitlements, PostgREST, Storage, Realtime, or Edge Functions to SDK-specific
types. `AuthenticationProvider` remains the interface consumed by
`AccountSessionStore`; a new `SupabaseGoogleAuthenticationProvider` is the only
production-capable implementation.

The entitlement endpoint is called with `URLSession` through an injected
`EntitlementTransport`. This keeps the endpoint contract independently testable
and replaceable while sending only an Authorization bearer token and bounded
request metadata.

## 4. Environments And Configuration

`AuthEnvironment` becomes:

- `disabled`: no account UI or credential access;
- `mock`: current deterministic local provider and Test Pro fixtures;
- `staging`: Supabase Google sign-in and staging entitlement service; and
- `production`: compiled support exists, but activation requires a separately
  approved release configuration.

The application does not select a network environment from an arbitrary runtime
URL. A build-generated, non-secret configuration resource supplies:

- exact Supabase project URL;
- Supabase publishable key;
- exact redirect URL;
- exact entitlement issuer and audience;
- allowed Edge Function origin; and
- pinned entitlement public keys by `kid`.

The build rejects missing, malformed, non-HTTPS, userinfo-bearing, query-bearing,
fragment-bearing, or unexpected-host URLs. The publishable key is permitted in
the client. The service-role key, entitlement signing private key, Google client
secret, and future payment credentials are prohibited from source, resources,
build logs, app bundles, fixtures, and diagnostics.

Public Free builds without an approved backend configuration remain accountless
and Free. Internal builds may select `mock` or `staging` explicitly. No unknown
environment value silently enables network authentication.

## 5. Google Sign-In Flow

1. The signed-out account UI requests Google sign-in.
2. `AccountSessionStore` begins one cancellable operation and resolves the
   Google provider from `AuthenticationProviderRegistry`.
3. `SupabaseGoogleAuthenticationProvider` asks Supabase Auth to start Google
   OAuth with PKCE and the exact registered redirect URL.
4. Supabase Auth presents `ASWebAuthenticationSession`; no embedded `WKWebView`
   is used.
5. Google authenticates the user and redirects through Supabase to the exact
   app callback.
6. Supabase Auth validates the callback binding and exchanges the authorization
   code using the PKCE verifier.
7. The provider maps the Supabase session to app-owned values. The account key
   is the Supabase user UUID. Email is optional display data and never the
   ownership key.
8. The existing store validates the mapped session, writes only the refresh
   credential and bounded account summary to the current environment's Keychain
   namespace, retains the access token in memory, and publishes `signedIn`.
9. Entitlement refresh starts only after credential commit succeeds.

Google scopes are limited to OpenID identity (`openid`, `email`, and `profile`).
The app does not request YouTube, Drive, Contacts, channel, upload, or media
permissions.

Cancellation before the credential commit boundary restores the prior stable
state. A late callback cannot overwrite a newer operation. OAuth callback URLs,
authorization codes, PKCE values, access tokens, refresh credentials, provider
errors, and user email are never logged.

## 6. Session Storage And Refresh

The existing `CredentialVault` remains the sole application authority for
persistent authentication credentials. Supabase Auth receives an app-owned
ephemeral `AuthLocalStorage` implementation that keeps SDK state in memory and
is discarded at process exit. It never writes a second persistent session.

After browser sign-in or refresh, `SupabaseGoogleAuthenticationProvider` maps
the SDK session into `AuthenticationSession`; `AccountSessionStore` then writes
the one `StoredCredentialEnvelope` through `CredentialVault`. On launch the
store loads that envelope and passes its refresh credential to the provider's
explicit `refreshSession(refreshToken:)` operation. This preserves one storage
writer and prevents SDK and app Keychain records from diverging.

Required storage properties are unchanged:

- data-protection Keychain;
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`;
- no iCloud synchronization;
- one replaceable session envelope per environment;
- no access token at rest; and
- no fallback to `UserDefaults`, files, diagnostics, or download persistence.

On launch, restoration reads the refresh credential and asks Supabase Auth to
refresh it. Supabase token rotation replaces the stored refresh credential only
after a valid response has been mapped and validated. A revoked or expired
credential becomes `requiresReauthentication`; it does not delete jobs, media,
history, settings, or a still-valid cached entitlement.

Logout asks Supabase to revoke the current session, clears the in-memory access
token, deletes only the active environment credential, and immediately applies
Free. If Keychain deletion fails, the current retryable cleanup behavior is
preserved and no second provider logout is sent.

## 7. Supabase Database Model

The initial migration creates these server-owned tables in a private schema:

### `account_profiles`

- `user_id uuid primary key references auth.users(id) on delete cascade`
- `display_name text null`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`

The application does not need direct profile-table access for this milestone.
Email remains in Supabase Auth and is not duplicated here.

### `entitlement_grants`

- `user_id uuid primary key references auth.users(id) on delete cascade`
- `plan text not null check (plan in ('free', 'pro'))`
- `status text not null check (status in ('none', 'active', 'suspended'))`
- `features text[] not null default '{}'`
- `max_video_height integer null`
- `valid_from timestamptz not null`
- `valid_until timestamptz null`
- `revision bigint not null default 1`
- `updated_at timestamptz not null default now()`

For Pro, `max_video_height = null` means unlimited under schema version 1. A
non-null value must be positive. Free is never read from this table as an
authority to expand access: missing, inactive, suspended, expired, malformed,
or unsupported records derive the canonical Free grant.

### `entitlement_audit_events`

- append-only UUID event ID;
- affected `user_id`;
- event type from a constrained set;
- previous and next revision;
- actor class, not raw provider credentials;
- event timestamp; and
- bounded non-secret reason code.

RLS is enabled on all tables. Authenticated clients have no insert, update, or
delete policy for entitlement or audit tables. The Edge Function uses its
server-side role only after verifying the caller and never accepts a user ID or
plan from the request body. Development grant changes use reviewed SQL fixtures
or an isolated test helper, not an app-exposed switch.

## 8. Entitlement Edge Function

The initial endpoint is:

`POST /functions/v1/entitlement`

Request:

- `Authorization: Bearer <Supabase access token>`;
- `Content-Type: application/json`;
- body `{ "schema": 1, "platform": "macos" }`.

It does not accept account ID, requested plan, requested features, installation
fingerprint, media information, or download information.

The function:

1. rejects missing or invalid Supabase authentication;
2. obtains the caller UUID from the verified JWT;
3. reads only that caller's current grant;
4. derives Free unless an active, in-window, internally consistent Pro grant
   exists;
5. constructs stable claims with a 24-hour entitlement lifetime;
6. signs the compact JWS with the active ES256 private key stored as an Edge
   Function secret; and
7. returns `{ "token": "<compact-jws>" }` with `Cache-Control: no-store`.

No raw access token, grant row, database error, key material, user email, or
provider response is returned or logged. Error responses use stable bounded
codes and a request ID that carries no account data.

## 9. Signed Entitlement Contract

The compact JWS protected header contains exactly:

- `alg: ES256`
- `kid: <reviewed key identifier>`
- `typ: JWT`

Schema version 1 payload claims are:

| Claim | Rule |
| --- | --- |
| `iss` | Exact configured entitlement issuer |
| `aud` | Exact macOS product identifier |
| `sub` | Supabase user UUID |
| `iat` | Issue time |
| `nbf` | Not-before time |
| `exp` | 24 hours after issue |
| `jti` | Unique random token ID |
| `schema` | Integer `1` |
| `plan` | `free` or `pro` |
| `features` | Stable feature-ID array |
| `maxVideoHeight` | Positive integer or `null` for Pro unlimited |
| `subscriptionState` | `none` or `active` in this milestone |
| `grantRevision` | Monotonic server grant revision |

The app verifies compact structure, canonical base64url, known `alg`, known
`kid`, ES256 signature, issuer, audience, subject match, clock claims, schema,
plan/feature consistency, video limit, subscription state, and revision shape
before constructing `EntitlementSnapshot`.

Unknown feature IDs are ignored. Unknown schema, algorithm, key, or malformed
claims fail closed. Cross-runtime tests pin the JWS ES256 raw `R || S` signature
representation so Deno Web Crypto and CryptoKit cannot accidentally disagree.

The private key exists only in Supabase secrets. The app contains a small
public-key ring keyed by `kid`. Rotation deploys a new public key before the
function begins signing with its matching private key; the retired public key
remains until every token and offline grace issued under it has expired.

## 10. Entitlement Cache And Offline Rules

The most recent verified compact JWS may be stored in a separate scoped
Keychain record. Unverified network bytes are never persisted.

- Normal token lifetime: 24 hours.
- Refresh: after sign-in, on app activation when near expiry, after explicit
  account refresh, and after a successful session refresh.
- Previously verified Pro offline grace: through 72 hours after `exp`.
- Never-verified, malformed, subject-mismatched, or Free tokens receive no Pro
  grace.
- After grace, the app preserves account and local data but applies Free.
- A lower valid `grantRevision` cannot replace a newer cached revision for the
  same subject.
- Logout immediately discards the cached entitlement and applies Free.
- Account changes discard cached entitlement before adopting the new subject.

Network outage, server error, authentication failure, entitlement rejection,
and clock error are distinct localized states. None exposes raw OAuth, JWT,
database, or Edge Function messages.

## 11. Plan And Feature-Policy Integration

`PlanController` gains a provider-neutral verified-entitlement input. Its source
priority is:

1. internal Test Pro override, only in `YTDP_INTERNAL_TEST` builds;
2. currently valid or grace-eligible verified server entitlement;
3. canonical Free.

Public builds do not compile the internal switch. A public signed-in user is
still Free until a verified Pro entitlement is accepted. Login alone never
grants Pro.

Applying a new snapshot publishes one plan change that the existing store and
runner observe. The existing downgrade behavior remains: active work may finish,
but queued, retrying, or newly admitted Pro work is restricted. Upgrade removes
the restriction without silently starting paused work. Views are presentation;
the store and runner remain enforcement authorities.

## 12. User Interface

The existing account surfaces are reused with these changes:

- public or staging account UI presents Google only;
- Apple remains absent until a separate approved design;
- sign-in explains that Free works without an account;
- signed-in presentation shows display name, masked email only where approved,
  current verified plan, last successful entitlement refresh, and offline state;
- refresh and logout are explicit controls;
- a signed-in Free user continues to see Pro locks and the local plan
  introduction page;
- the upgrade button remains non-payment and cannot imply that Pro is available
  for purchase; and
- internal Test Pro is visibly marked as a local engineering override.

All new copy must exist in Traditional Chinese, Japanese, and English and use
typed localization keys. Raw provider strings never reach alerts.

## 13. Diagnostics And Privacy

Permitted diagnostic categories are payload-free, for example:

- authentication started, cancelled, completed, expired, or failed;
- session refresh succeeded or required reauthentication;
- entitlement refresh succeeded, was unavailable, was rejected, or used
  offline grace; and
- signature validation failed by bounded reason class.

Diagnostics must never include tokens, refresh credentials, JWS contents,
authorization codes, PKCE verifier/challenge, state, nonce, callback URL,
Supabase project URL/key, email, full user UUID, Google subject, media data,
download data, database rows, or server error bodies.

Support reports and local exports exclude credentials and entitlement tokens.
An optional account-status summary may include only signed-in/out, Free/Pro,
offline-grace yes/no, and bounded error category after explicit user review.

## 14. Failure Behavior

| Failure | Behavior |
| --- | --- |
| User cancels browser | Restore prior stable state; do not mutate credentials or plan |
| Callback or PKCE flow fails | Generic localized retry; no session adoption |
| Keychain save fails | Reject session adoption; remain safely signed out |
| Refresh token is revoked | Require Google sign-in; keep local downloads and history |
| Edge Function is unavailable | Use valid token or eligible grace; otherwise Free |
| Edge Function says unauthorized | Refresh session once, retry once, then require sign-in |
| Signature/key/issuer/audience/subject invalid | Reject token and preserve only a separately valid cached token |
| Token expires during an active download | Do not terminate active process; recheck admission before retry/new work |
| New verified Free or suspended result | Apply Free immediately and reconcile non-active work |
| Clock is outside allowed skew | Apply Free unless an independently valid cached grant exists; show clock guidance |

Retries are bounded and never loop between auth and entitlement refresh.

## 15. Test Strategy

Implementation follows red-green-refactor. Tests use fake transports and fixed
clocks; normal unit tests never open a browser, access production Keychain, or
contact Supabase.

### Swift tests

- environment configuration allowlist and secret rejection;
- Google provider mapping, cancellation, late callback, refresh rotation,
  revocation, and sanitized errors;
- Keychain single-writer and no-access-token-at-rest invariants;
- entitlement request body/header privacy;
- valid ES256 fixture generated by the Edge Function test implementation;
- malformed compact JWS and non-canonical base64url;
- unknown algorithm/key/schema/feature;
- invalid signature, issuer, audience, subject, time, plan, feature, limit, and
  revision;
- valid, expired, and 72-hour grace boundaries with fixed clocks;
- account change, logout, lower revision, outage, unauthorized retry, and
  failure-to-Free behavior;
- immediate `PlanController` propagation to view, store, and runner boundaries;
- public build has no internal plan switch;
- localization completeness and bounded presentation.

### Edge Function tests

- missing, malformed, expired, and wrong-project bearer token;
- identity is derived only from verified authentication;
- missing/inactive/expired/suspended/malformed grant derives Free;
- active Pro derives the exact reviewed feature set;
- request cannot select another subject or request Pro;
- output claims, 24-hour lifetime, unique `jti`, monotonic revision, and
  `Cache-Control: no-store`;
- missing private key fails without leaking configuration;
- logs and responses contain none of the prohibited fields; and
- ES256 output verifies against the same fixture in CryptoKit.

### Verification gates

- focused Swift tests for each red-green cycle;
- complete public and internal strict-concurrency suites with warnings as
  errors;
- SQL lint and migration reset against a disposable local Supabase stack;
- Edge Function unit tests without network;
- staging-only manual Google sign-in after the owner creates and configures the
  external projects;
- bundle inspection proving no secret or internal plan control is present in a
  public build.

## 16. Repository Structure

Planned source boundaries:

- `swift-2.0/Sources/YTDownloaderPro2/Authentication/SupabaseAuthConfiguration.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Authentication/SupabaseGoogleAuthenticationProvider.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Authentication/SupabaseAuthStorage.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementClient.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementToken.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementVerifier.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementStore.swift`
- `supabase/migrations/202609230001_account_entitlements.sql`
- `supabase/functions/entitlement/index.ts`
- `supabase/functions/entitlement/contract.ts`
- `supabase/functions/entitlement/contract_test.ts`

Each production file has one clear responsibility. Supabase SDK types do not
cross into SwiftUI, feature policy, download models, persistence, or runner
interfaces.

## 17. Delivery Sequence

1. Add configuration and privacy contracts.
2. Add Supabase SQL schema, RLS, deterministic grant derivation, and Edge
   Function signing tests.
3. Add the pinned Auth package and Keychain storage adapter.
4. Implement Google system-browser PKCE and session lifecycle behind the
   existing provider protocol.
5. Implement entitlement HTTP client and ES256 verifier.
6. Connect verified snapshots to `PlanController` and reconcile policy changes.
7. Complete account UI, localization, diagnostics, and documentation.
8. Run strict suites, security/privacy review, bundle inspection, and staging
   walkthrough.

Each step must be independently reviewed and committed. A failing security,
privacy, strict-concurrency, localization, bundle, or entitlement test blocks
the next step.

## 18. External Setup Gate

Code and local tests may be completed before external setup. The owner must
explicitly approve each external action before it occurs:

1. create development and staging Supabase projects;
2. choose and record the approved region and data-processing terms;
3. create the Google Cloud OAuth project and consent branding;
4. register the exact redirect URL in Google and Supabase;
5. install only the publishable staging configuration locally;
6. provision the Edge Function signing private key as a Supabase secret; and
7. run a real staging sign-in with a designated test account.

Production setup, production users, payment data, recurring billing, public Pro
claims, and release remain prohibited until the existing launch gates are met
and a new owner approval is recorded.

## 19. References

- `ENTITLEMENT_ARCHITECTURE.md`
- `COMMERCIAL_FEASIBILITY.md`
- `PRIVACY_DATA_MAP.md`
- `PRIVACY_THREAT_MODEL.md`
- `docs/swift-2.0/AUTHENTICATION.md`
- `docs/swift-2.0/ENTITLEMENT_ARCHITECTURE.md`
- Supabase Swift OAuth reference:
  <https://supabase.com/docs/reference/swift/auth-signinwithoauth>
- Supabase Swift session refresh reference:
  <https://supabase.com/docs/reference/swift/auth-refreshsession>
- Supabase native deep-linking guide:
  <https://supabase.com/docs/guides/auth/native-mobile-deep-linking?platform=swift>
- Supabase Edge Functions:
  <https://supabase.com/docs/guides/functions>
