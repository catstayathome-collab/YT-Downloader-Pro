# Swift Authentication Skeleton Design

## Document Control

| Field | Value |
| --- | --- |
| Status | Approved in-chat design; awaiting written-spec review |
| Product | YT Downloader Pro macOS Swift 2.x |
| Phase | Phase 1 local authentication skeleton |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-12 |
| Production authentication | Explicitly out of scope |

## 1. Decision Summary

YT Downloader Pro will prepare for optional Google and Apple sign-in through a
provider-neutral Swift authentication layer. Phase 1 is a local-only skeleton:
it provides the final account UI shape, session state machine, credential-vault
boundary, mock providers, tests, and maintenance documentation without
contacting an identity provider or YT Downloader Pro backend.

The normal public build remains accountless. Free downloads continue to work
without sign-in. Mock account controls appear only when the process is launched
with `YTDP_AUTH_MODE=mock`. A missing, empty, or unknown value resolves to
authentication disabled and must never grant paid capabilities.

This design is consistent with `COMMERCIAL_FEASIBILITY.md`: it is non-payment
technical preparation, not authorization to collect identity data, enable
checkout, advertise Pro as available, or launch a paid service.

## 2. Goals

- Establish stable Swift interfaces that both Google and Apple providers can
  implement later without rewriting account views or session management.
- Let engineers exercise sign-in, restoration, expiry, error, and sign-out UI
  using synthetic local data.
- Store the mock refresh credential through a Keychain abstraction so restart
  restoration follows the same boundary expected in production.
- Keep authentication independent of downloads, local history, settings,
  diagnostics, billing, and feature enforcement.
- Make privacy and failure behavior explicit and testable.
- Document the system well enough for a new engineer to add a reviewed staging
  provider without guessing the intended boundaries.

## 3. Non-Goals And Hard Boundaries

Phase 1 must not:

- Register or call Google, Apple, ECPay, a backend, analytics, email, support, or
  any other external service.
- Open a browser, embedded web view, callback listener, or custom URL scheme.
- Include OAuth client IDs, client secrets, signing keys, production endpoints,
  payment credentials, or real user fixtures.
- Collect, persist, upload, or associate real names, email addresses, media
  URLs, titles, download paths, cookies, thumbnails, or history with an account.
- Enforce Free or Pro restrictions. Mock plan labels are presentation-only and
  must not alter format selection, queue behavior, downloads, or support.
- Change the existing update mechanism or the Windows Python product line.

Real staging authentication is a separate phase. It requires a reviewed
implementation plan and the applicable privacy, security, provider, domain,
Apple Developer, and commercial approval gates. Production payment and paid
feature enforcement remain blocked by all launch gates in
`COMMERCIAL_FEASIBILITY.md`.

## 4. Architecture

### 4.1 Components

`AuthEnvironment`

- Resolves once at process launch from `YTDP_AUTH_MODE`.
- Supports `.disabled` and `.mock` in Phase 1.
- Unknown values fail closed to `.disabled` and may produce only a sanitized
  local diagnostic stating that the value was unsupported.
- Future `.staging` and `.production` cases require separate approval and are
  not added speculatively in this phase.

`AuthenticationProvider`

- Defines provider-neutral operations to start sign-in, restore a stored
  session, and revoke provider-local session material during sign-out.
- Returns domain values rather than provider SDK types.
- Receives no download store, media URL, output path, cookie setting, history,
  billing object, or view reference.

`AccountSessionStore`

- Is the single observable source of account presentation state.
- Serializes authentication operations so only one sign-in, restoration, or
  sign-out transition can mutate state at a time.
- Validates provider identity, opaque account identity, and expiry before
  adopting a session.
- Keeps any short-lived access token in memory only.
- Coordinates refresh-credential persistence through `CredentialVault`.
- Does not own downloads, settings, entitlements, billing, or feature policy.

`CredentialVault`

- Defines save, load, and delete operations for an opaque refresh credential.
- Maintains at most one active session envelope per authentication environment;
  the envelope identifies its provider and contains the opaque credential.
- Uses separate service namespaces so mock, staging, and production credentials
  can never collide.
- Has no API for enumerating unrelated Keychain entries.

`KeychainCredentialVault`

- Is the macOS implementation used by the app.
- Stores only the minimum opaque credential and restoration metadata.
- Uses a product-specific service name and
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Never synchronizes authentication credentials through iCloud Keychain.

`InMemoryCredentialVault`

- Is the deterministic implementation used by unit tests.
- Prevents the normal test suite from reading or modifying the developer's real
  Keychain.

`MockAuthenticationProvider`

- Implements the same protocol intended for future real providers.
- Produces synthetic, randomly generated opaque account and credential values.
- Performs no network, browser, callback, filesystem, billing, or download
  operation.
- Supports deterministic injected clocks and failure outcomes for tests.

`AccountSummary`

- Contains only provider kind, opaque account identifier, synthetic display
  label, presentation plan label, and relevant expiry state.
- Exposes no credential value to SwiftUI.

### 4.2 Session State

The store exposes one explicit state:

- `disabled`: account functionality is unavailable and its UI is absent.
- `signedOut`: free accountless operation.
- `signingIn(provider)`: one provider attempt is in progress.
- `restoring`: a stored mock session is being validated.
- `signedIn(AccountSummary)`: a valid synthetic mock session.
- `requiresReauthentication(provider?)`: stored session is expired or invalid.
- `failed(AuthPresentationError)`: recoverable localized failure state.
- `signingOut`: credential removal is in progress.

The UI renders these states but does not infer account status from individual
optional fields. The store is the only component allowed to transition between
states.

## 5. Data Flow And Security

### 5.1 Mock Sign-In

1. The user selects Google or Apple in the account settings view.
2. The view asks `AccountSessionStore` to start sign-in for that provider.
3. The store enters `signingIn` and rejects or coalesces additional attempts.
4. The selected mock provider creates a synthetic account result and opaque
   refresh credential without network access.
5. The store validates provider, non-empty opaque account identity, and expiry.
6. The refresh credential and minimum restoration metadata are written through
   `CredentialVault`.
7. The short-lived access token remains in memory only.
8. The store publishes `signedIn(AccountSummary)`.

A vault-write failure prevents the session from being adopted. The user sees a
localized account-storage error and downloads continue unchanged.

### 5.2 Launch Restoration

1. In `.disabled`, the app performs no credential lookup and remains accountless.
2. In `.mock`, the store loads the single active envelope from the mock
   namespace and reads its provider kind.
3. The matching provider validates the synthetic credential and reconstructs a
   session.
4. Valid data becomes `signedIn`; expired data becomes
   `requiresReauthentication`.
5. Corrupt or structurally invalid data is removed from the mock namespace and
   produces a safe signed-out or reauthentication state.

Restoration failure must not delay application startup indefinitely, crash the
app, delete local data, or pause downloads.

### 5.3 Sign-Out

1. The store enters `signingOut` and asks the provider to discard local
   provider state.
2. The corresponding vault record is deleted.
3. The store enters `signedOut`.

Sign-out removes only authentication session material. It does not delete media
files, queue entries, download history, cached thumbnails, diagnostics, output
folder choices, or app settings. Phase 1 therefore does not require a
destructive-action confirmation dialog; the UI states this consequence near
the sign-out button.

### 5.4 Privacy And Logging

- Authentication APIs accept no media or download context.
- Diagnostics never record token material, complete opaque account IDs, email
  addresses, Keychain payloads, authorization codes, nonces, or provider error
  bodies.
- Allowed diagnostics are bounded event categories such as sign-in started,
  cancelled, storage unavailable, session expired, and sign-out completed.
- Unknown environment values and failures are sanitized before logging.
- Swift errors shown to users are localized app-owned messages, not raw
  Security framework or future provider error strings.

## 6. User Interface

### 6.1 Availability

- In `.disabled`, account UI is completely absent from the sidebar and settings.
- In `.mock`, account UI is visible and carries a persistent
  "Development Test Mode" notice in the settings account section.
- Account UI never blocks, replaces, or conditions the existing URL analysis
  and download workflow.

### 6.2 Sidebar Summary

The compact account row is located at the bottom of the download sidebar.

| State | Primary label | Secondary label |
| --- | --- | --- |
| Signed out | Sign in or view plans | Free; no sign-in required |
| Signing in/restoring | Signing in | Downloads are unaffected |
| Signed in | Synthetic display label | Mock provider and test plan |
| Reauthentication required | Sign in again | Free downloads remain available |
| Recoverable failure | Account unavailable | Open settings to retry |

Selecting the row opens account settings. A progress indicator replaces the
avatar while an operation is active, and duplicate controls are disabled.

### 6.3 Account Settings

The account section appears at the top of Settings when mock mode is enabled.

Signed out:

- Google and Apple mock sign-in buttons.
- Current status and free-plan preview.
- Short explanation that free downloads do not require an account.

Signing in or restoring:

- Progress indicator and neutral status message.
- Provider controls disabled until completion or cancellation.
- Explicit statement that active downloads continue.

Signed in:

- Synthetic display label, mock provider, and test-plan preview.
- Sign-out button.
- Explanation that sign-out preserves downloads and local data.

Expired or invalid:

- Clear reauthentication message and retry action.
- No raw technical provider error.
- Free download availability remains clear.

### 6.4 Interaction And Accessibility

- Account controls support keyboard focus and activation.
- VoiceOver labels describe provider, state, progress, retry, and sign-out
  actions without relying on icons alone.
- Focus order follows the visual order and returns predictably after a sheet or
  operation completes.
- All user-facing strings are present in Traditional Chinese, English, and
  Japanese through the existing localization system.
- Cancelling a future sign-in sheet returns focus to the initiating control and
  leaves the previous account state unchanged.

## 7. Error Handling And Concurrency

| Condition | Required behavior |
| --- | --- |
| User cancellation | Restore the prior stable state; do not show an error |
| Mock provider failure | Show a localized retryable message; preserve downloads |
| Keychain unavailable | Do not adopt a non-restorable session; show storage error |
| Missing credential | Return to signed out without crashing |
| Expired credential | Require reauthentication; do not claim Pro |
| Corrupt credential | Reject and remove only the affected mock record |
| Provider mismatch | Reject the session and require reauthentication |
| Duplicate rapid sign-in | Permit only one mutating operation |
| App exits during operation | Persist no partial session as valid |
| Unsupported auth mode | Fail closed to disabled account UI |

Authentication operations are serialized by the store. Each completion is
associated with the operation that initiated it, so a stale asynchronous result
cannot overwrite a newer sign-out or provider selection. Download execution is
not part of this serialization and continues independently.

## 8. Testing Strategy

### 8.1 Unit Tests

- Every valid state transition, including sign-in, restoration,
  reauthentication, failure recovery, and sign-out.
- Cancellation restores the prior stable state.
- Vault-write failure prevents session adoption.
- Expired, corrupt, empty, and provider-mismatched credentials fail safely.
- Rapid duplicate requests result in one mutating operation.
- Stale asynchronous completions cannot overwrite a newer state.
- Sign-out deletes only the active envelope in the current authentication
  environment.
- Sign-out preserves jobs, history, settings, cached thumbnails, and media.
- Disabled mode performs no vault load and exposes no account presentation.
- Mock providers perform no network or browser operation by construction.
- Diagnostic serialization redacts credentials and full account identifiers.

The normal test suite uses `InMemoryCredentialVault`, an injected clock, and
deterministic mock outcomes.

### 8.2 Keychain Integration Test

One focused integration suite uses a disposable, test-only Keychain service
namespace. It verifies save, replacement, load, and deletion, then performs
cleanup regardless of test outcome. It must never use the production service
name or existing user records.

### 8.3 UI And Localization Tests

- Sidebar and Settings are absent in disabled mode.
- All four visible mock states match the approved presentation.
- Active operations disable duplicate controls and expose progress to
  accessibility APIs.
- Keyboard focus and VoiceOver labels are correct.
- Traditional Chinese, English, and Japanese strings exist and fit supported
  window sizes.
- Account interactions do not pause or mutate a representative active download.

### 8.4 Verification

Focused authentication tests run first. The full strict Swift suite then runs
with a project-local `CLANG_MODULE_CACHE_PATH` and `--disable-sandbox`, followed
by a release build and `git diff --check`. No Phase 1 verification step may
contact Google, Apple, ECPay, or a YT Downloader Pro backend.

## 9. Documentation Deliverables

Implementation must add or update:

- `docs/swift-2.0/AUTHENTICATION.md`: component contracts, state transitions,
  test-mode operation, Keychain namespace, and reviewed extension points.
- `ENTITLEMENT_ARCHITECTURE.md`: Apple identity support and the shared account
  core, while preserving the backend-owned entitlement boundary.
- `PRIVACY_DATA_MAP.md`: mock-session fields, storage location, retention, and
  data explicitly excluded from authentication.
- `PRIVACY_THREAT_MODEL.md`: credential theft, diagnostics leakage,
  environment confusion, stale completion, and namespace isolation threats.
- Developer instructions for enabling and disabling `YTDP_AUTH_MODE=mock` and
  confirming that the normal public build hides all account UI.

Documentation must distinguish implemented Phase 1 behavior from future
staging and production proposals. It must not imply that Google, Apple, ECPay,
subscriptions, cloud history, or paid support are operational.

## 10. Delivery Sequence

1. Add authentication domain types and environment resolution with red-first
   unit tests.
2. Add the credential-vault protocol, in-memory implementation, and isolated
   Keychain implementation with tests.
3. Add the deterministic mock provider and serialized session store with
   state-machine tests.
4. Add conditional app integration and sidebar account summary.
5. Add account settings states, accessibility, and localization.
6. Add diagnostic redaction and failure-path tests.
7. Update architecture, privacy, and developer documentation.
8. Run focused tests, the full strict suite, release build, static checks, and a
   manual disabled-mode/mock-mode smoke test.

Each implementation commit should remain small, reviewable, and internally
complete. Real-provider work begins only under a separately approved design and
plan.

## 11. Acceptance Criteria

Phase 1 is complete only when all of the following are true:

- A normal launch exposes no account UI and behaves like the existing free app.
- `YTDP_AUTH_MODE=mock` exposes the approved sidebar and Settings UI.
- Google and Apple mock paths exercise the same provider-neutral interfaces.
- A mock session can be restored after restart through the vault boundary.
- Invalid or expired session material fails closed without affecting downloads.
- Sign-out removes only authentication material.
- No real identity, network, browser callback, payment, backend, or entitlement
  behavior exists in the shipped code path.
- Credentials and complete account identifiers are absent from diagnostics.
- Accessibility and all three supported localizations are verified.
- Focused tests, full strict Swift tests, release build, and static checks pass.
- Maintenance documentation clearly identifies implemented behavior, future
  extension points, and launch gates.
