# Swift 2.0 Authentication Skeleton

## Phase 1 Status

The Swift 2.x authentication feature is an implemented local mock skeleton for
development and deterministic testing. It is not production authentication.
It does not contact Google, Apple, a YT Downloader Pro backend, a billing
provider, or an entitlement service. It does not deliver entitlements, enforce
paid features, submit data, open browser authentication, or use a real account.

Google and Apple are mock provider labels in this phase. Apple is only a future
identity-provider candidate. Any real identity, account, entitlement, billing,
or backend work requires its own approved design and plan before implementation.

Free downloads remain available without an account. Mock plan labels are
presentation-only and do not change download, queue, format, history, settings,
or media behavior.

## Component Responsibilities

| Component | Implemented responsibility | Not implemented |
| --- | --- | --- |
| `AuthEnvironment` | Resolves the local mode once from `YTDP_AUTH_MODE`. | Staging or production modes. |
| `AccountSessionStore` | Owns observable mock session state, serializes operations, validates local sessions, and owns in-memory access material. | Downloads, settings, feature policy, entitlements, billing, or backend calls. |
| `AccountSummary` | Carries synthetic provider, account identifier, display, plan, and expiry presentation data to SwiftUI. It exposes no access token or refresh credential. | Credential storage or provider revocation. |
| `AuthenticationProvider` | Defines the provider-neutral mock sign-in, restoration, and local sign-out boundary. | Provider SDKs, browser callbacks, OAuth, or network I/O. |
| `MockAuthenticationProvider` | Produces synthetic Google or Apple-labelled sessions and validates their local restoration envelope. | Google or Apple identity authentication. |
| `CredentialVault` | Saves, loads, and deletes one opaque restoration envelope for an authentication environment. | Credential enumeration, cloud sync, or unrelated Keychain access. |
| `KeychainCredentialVault` | Persists the active local restoration envelope in macOS Keychain. | iCloud Keychain sync, production credentials, or provider revocation. |
| `InMemoryCredentialVault` | Provides deterministic non-Keychain storage for normal tests. | Persistent app storage. |
| `AuthenticationDiagnosticEvent`, `AuthenticationDiagnosticsRecording`, and `SystemAuthenticationDiagnosticsRecorder` | Record a finite set of payload-free local diagnostic categories. | Analytics, raw error capture, or external reporting. |
| `AccountSidebarView` and `AccountSettingsSection` | Render mock-only account presentation and safe state-specific controls. | Account recovery, purchase, entitlement, or real provider UI. |
| `AppLifecycle` | Starts asynchronous mock-session restoration after application launch. | Blocking launch, download ownership, or authentication-driven download cancellation. |

## State Transitions

| State | Entry and exit behavior |
| --- | --- |
| `disabled` | Used when the environment is not exact mock mode. Account UI is absent; restoration performs no vault read and remains disabled. |
| `signedOut` | Mock mode's stable, accountless state. A provider selection begins `signingIn`; empty restoration returns here; successful sign-out returns here. |
| `restoring` | Entered by application lifecycle restoration in mock mode and reused while retrying invalid-restoration cleanup. A valid envelope becomes `signedIn`; an expired one requires reauthentication; malformed or invalid material is deleted from the current mock record. Once deletion begins, it is non-cancellable even while this state remains visible; cancellation before that boundary restores the prior stable state. |
| `signingIn(provider)` | Entered for one selected mock provider. A validated session that is saved successfully becomes `signedIn`. Once credential saving begins, it is non-cancellable even while this state remains visible; cancellation before that boundary restores the prior stable state. Failures become a localized recoverable failure. |
| `signedIn(summary)` | Contains only the synthetic presentation summary. Sign-out enters `signingOut`; an expired or invalid restoration requires reauthentication. |
| `requiresReauthentication(provider?)` | Signals expired or rejected stored material. A known provider can retry it; an unknown provider presents both local mock choices. Free downloads remain available. |
| `failed(error)` | A recoverable presentation error. `credentialRemovalFailed` retries the store-owned credential cleanup operation, preserving whether the failure followed invalid restoration or sign-out; other failures present local mock sign-in choices. |
| `signingOut` | Clears the in-memory access token before asking the mock provider to discard local state, but retains the summary and refresh credential until deletion of the current environment envelope succeeds. Once deletion begins, it is non-cancellable while this state remains visible. Success clears the retained summary and refresh credential and becomes `signedOut`; deletion failure becomes `failed(credentialRemovalFailed)`. |

Only one mutating authentication operation may own the store at a time. A newer
cancellation invalidates the active operation, so a stale asynchronous provider
result cannot overwrite the restored prior state. Download execution is outside
this serialization and continues independently.

Credential save and deletion are commit/cleanup boundaries. They retain the
visible `signingIn`, `restoring`, or `signingOut` state while the vault call is
in flight, but disable cancellation and keep exclusive operation ownership
until its result is committed. A failed invalid-restoration cleanup retries the
same scoped deletion and then reaches `requiresReauthentication(nil)` on
success. A failed sign-out deletion retries deletion only, without a second
provider sign-out, and then reaches `signedOut` on success.

## Local Mock Mode

Enable the implemented local mock skeleton with the exact invocation:

```sh
YTDP_AUTH_MODE=mock
```

Authentication is disabled when `YTDP_AUTH_MODE` is unset or has any value
other than lowercase `mock`, including `MOCK`, an empty value, and
`production`. In disabled mode, the sidebar and Settings show no account
controls and the app does not load a credential envelope.

The app lifecycle starts `restoreSession()` after launch. In mock mode the
account UI can show restoring or sign-in progress and offers cancellation only
before credential saving or deletion reaches its commit/cleanup boundary.
Invalid-restoration cleanup and its retry reuse restoring progress but are
non-cancellable. An accepted cancellation returns to the prior stable state; it
does not cancel, pause, mutate, or delete active downloads.

## Keychain Contract

`KeychainCredentialVault` uses the service prefix
`com.catstayathome.YTDownloaderPro.auth`. The complete service name appends the
authentication storage namespace, for example
`com.catstayathome.YTDownloaderPro.auth.mock`. The Keychain account key is
`active-session`.

There is exactly one generic-password restoration envelope per authentication
environment. Saving replaces that single envelope rather than creating a second
record. The envelope contains the synthetic account summary and opaque mock
refresh credential; the short-lived access token stays in memory and is not
encoded into the envelope. The record uses
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, is not synchronizable, and uses
the data-protection Keychain. The data-protection Keychain is mandatory for
this macOS accessibility contract; removing `kSecUseDataProtectionKeychain`
would make the requested accessibility class ineffective on macOS. The release
app therefore needs a Developer ID provisioning profile that authorizes the
exact application identifier and default Keychain access group.

An ad-hoc signature cannot carry these restricted entitlements. Internal
`--unsigned-test` bundles intentionally remain authentication-disabled and must
not be used as evidence that Keychain persistence works. Do not add fabricated
Team IDs, relax the data-protection query, or fall back to preferences or files
to make an internal build appear persistent.

The focused Keychain integration test is opt-in through
`YTDP_RUN_KEYCHAIN_INTEGRATION_TESTS=1`. It generates a disposable service
namespace of the form `com.catstayathome.YTDownloaderPro.tests.<UUID>` and its
teardown deletes only that test namespace's `.mock` and `.disabled` records.
It must never use the live service prefix or clean up user records. A plain
SwiftPM test process does not inherit the app's Keychain entitlement, so this
opt-in test is final evidence only when it runs from a correctly provisioned
and signed test host. On an unentitled host, `errSecMissingEntitlement` is the
expected fail-closed result.

To clear only the local mock authentication record, use an authenticated test
or a Keychain-aware maintenance path that deletes the generic password with:

- service: `com.catstayathome.YTDownloaderPro.auth.mock`
- account: `active-session`

Do not delete the disabled-namespace record, unrelated Keychain items, jobs,
history, settings, diagnostics, thumbnails, or downloaded media. The current
app's mock sign-out performs this same scoped deletion and preserves those
unrelated local data sets.

## Diagnostic Contract

The complete implemented diagnostic inventory is:

- `auth.sign-in.started`
- `auth.sign-in.cancelled`
- `auth.sign-in.failed`
- `auth.session.restored`
- `auth.session.expired`
- `auth.storage.unavailable`
- `auth.sign-out.completed`

Diagnostics record only these event categories. They must not include access
tokens, refresh credentials, complete account IDs, email addresses, Keychain
data, authorization codes, nonces, raw provider errors, media URLs, media
titles, output paths, cookies, history, jobs, or billing and entitlement data.

## Adding A Future Provider

1. Keep the provider-neutral boundary: implement `AuthenticationProvider` and
   return only app-owned domain values rather than provider SDK types.
2. Define the exact identity data, storage, diagnostics, cancellation, error,
   accessibility, localization, and deletion behavior before adding an SDK or
   network surface.
3. Preserve the rule that authentication APIs receive no download URL, media
   title, output path, cookie, history, job, billing, or entitlement object.
4. Add deterministic tests for state transitions, cancellation, stale results,
   storage failures, invalid material, privacy redaction, and UI presentation.
5. Complete the required provider, security, privacy, legal, commercial, and
   external-account approvals before any real provider interaction.
6. Obtain a new approved spec and plan before implementing the future provider.

## Troubleshooting

### Account UI Is Missing

Confirm the process environment contains exactly `YTDP_AUTH_MODE=mock`. Any
other value disables authentication and intentionally hides account controls.

### Mock Credential Is Expired

An expired restoration envelope produces `requiresReauthentication`. Sign in
again with the displayed local mock provider. This does not grant a real
account, entitlement, or paid feature, and does not affect downloads.

### Keychain Is Unavailable

The store does not adopt a non-restorable session when the vault save fails.
It reports the localized storage error and keeps downloads independent. Check
the local Keychain availability and retry; do not work around this by storing
credentials in preferences, files, diagnostics, or a network service.

### Clear Only Mock Authentication

Remove only the generic-password item for service
`com.catstayathome.YTDownloaderPro.auth.mock` and account `active-session`,
or use mock sign-out. This preserves jobs, settings, history, diagnostics,
thumbnails, and media.
