# Swift 2.0 Authentication

## Implemented Boundary

The app has two development authentication paths and a fail-closed disabled
default:

| Mode | Activation | Purpose | External effect |
| --- | --- | --- | --- |
| Disabled | `YTDP_AUTH_MODE` absent or unrecognized | Public/accountless Free | None |
| Mock | exact `YTDP_AUTH_MODE=mock` | Deterministic local UI and lifecycle tests | None |
| Staging | exact `YTDP_AUTH_MODE=staging` plus valid bundled configuration | Owner-approved Google PKCE staging tests | Supabase/Google staging only |

The local mock remains supported. The staging adapter is implemented but no
production account, payment, or public service is created by this repository.
The owner has configured a separate Supabase/Google staging project for internal
sign-in tests; this repository does not contain its private credentials. Apple remains a mock/future provider;
there is no live Sign in with Apple implementation.

Free downloads work without login. Identity never grants Pro. Only a valid,
cryptographically verified entitlement may affect the effective plan.

## Components

| Component | Responsibility |
| --- | --- |
| `SupabaseAuthConfiguration` | Strictly validates the bundled public-material configuration and exact app callback. |
| `AuthEnvironmentResolution` | Enables mock or configured staging only for exact mode values; otherwise disables authentication. |
| `AccountSessionStore` | Owns observable account state, serialized operations, cancellation ownership, in-memory access material, and scoped restoration. |
| `MockAuthenticationProvider` | Produces synthetic local sessions without browser or network access. |
| `SupabaseGoogleAuthenticationProvider` | Uses Supabase Auth's system-browser OAuth PKCE flow with `openid email profile`. |
| `EphemeralSupabaseAuthStorage` | Keeps Supabase SDK PKCE/session scratch data in process memory only. |
| `CredentialVault` | Stores one opaque refresh envelope per authentication environment. |
| `AccountEntitlementBridge` | Observes accepted account state and asks the entitlement controller to restore or refresh the matching grant. |

The app owns its domain models. Supabase SDK types do not cross the provider
adapter. `AccountSummary` contains provider, stable account ID, display name,
optional masked email, and expiry; it contains no access token, refresh token,
plan, or media activity.

## State And Race Contract

The store moves between `disabled`, `signedOut`, `signingIn`, `restoring`,
`signedIn`, `requiresReauthentication`, `failed`, and `signingOut`. One
operation owns the store at a time. Cancellation invalidates that operation so
a late browser, refresh, or vault response cannot overwrite newer state.

Credential save/deletion is a commit boundary. Once it begins, the visible
operation remains non-cancellable until the vault result is known. Account
replacement clears the previous entitlement before adopting the next account.
Logout invalidates in-flight entitlement work and cannot restore a late Pro
grant. Download lifecycle is independent of authentication lifecycle.

## Shared Account Identity Contract

The account key is `auth.users.id`, the immutable Supabase user UUID returned
after a verified Google sign-in. The app maps that UUID to `AccountSummary.accountID`;
the entitlement endpoint obtains the same UUID from the verified bearer token
and loads only the matching `private.entitlement_grants.user_id`. The endpoint
also refuses to grant Pro if a returned row belongs to another UUID. Email and
display name are presentation data, never lookup or authorization keys.

A future website must authenticate against the same approved Supabase project
and use the authenticated UUID for checkout and subscription ownership. It must
not accept a user ID or email supplied by a browser form as payment authority.
This repository does not yet contain a website sign-in flow, so a real App-to-web
same-account smoke test remains pending. Local tests cover changed email with
the same UUID, the same email with different UUIDs, and mismatched entitlement
rows. Logout and account replacement are covered by the account/entitlement
bridge tests; neither action cancels a subscription.

## Google Staging Flow

The staging provider uses Authorization Code with PKCE through the system
browser. It requests exactly:

```text
openid email profile
```

The exact app callback is:

```text
com.tachouweng.ytdownloaderpro2://auth/callback
```

The bundled configuration contains a Supabase publishable key and entitlement
verification public keys only. Missing, malformed, mismatched, secret-bearing,
or public-channel configuration fails closed. Operational setup is documented
in `SUPABASE_STAGING.md`.

## Keychain Contract

Authentication uses service prefix
`com.catstayathome.YTDownloaderPro.auth.<environment>` and account key
`active-session`. The envelope contains an identity summary and opaque refresh
credential. The short-lived access token stays in memory and is never encoded
into the envelope.

Entitlement storage is separate under
`com.catstayathome.YTDownloaderPro.entitlement.<environment>`. It stores only a
compact signed entitlement that must be reverified before adoption after
restart.

Both live vaults use the data-protection Keychain,
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and no synchronization. Sign-out
deletes the current environment's auth envelope and entitlement. It does not
delete settings, jobs, history, thumbnails, diagnostics, or downloaded media.

An ad-hoc app or plain SwiftPM process cannot prove the restricted Keychain
contract. Final persistence evidence requires the correctly provisioned
Developer ID test host and exact application identifier/access group.

## Diagnostics And Privacy

Authentication diagnostics are bounded event categories. They must not contain
access or refresh tokens, authorization codes, state, nonce, complete account
IDs, email addresses, Keychain data, raw provider errors, media URLs, titles,
paths, cookies, jobs, history, billing data, or entitlement tokens.

The identity and entitlement interfaces accept no media object. Normal account
and entitlement requests must not send download URLs, titles, thumbnails,
files, output paths, cookies, helper output, or download history.

## Development Use

Local mock:

```bash
YTDP_AUTH_MODE=mock swift run --package-path swift-2.0 YTDownloaderPro2
```

Staging mode is meaningful only in a configured internal app:

```bash
YTDP_AUTH_MODE=staging open 'dist/swift-2.0/internal-test/YT Downloader Pro 2.app'
```

Do not use staging test results to claim production login, account recovery,
server deletion, payment, billing, or public availability. Those remain gated
by external provider, legal, privacy, operations, signing, and owner approval.

## Troubleshooting

- Missing account UI: verify the exact mode and, for staging, that the internal
  bundle contains a valid configuration. Public bundles intentionally do not.
- Reauthentication required: the stored refresh credential was expired,
  rejected, malformed, or belongs to another account; sign in again.
- Storage unavailable: do not fall back to files or preferences. Verify the
  provisioned Keychain entitlements and retry.
- Entitlement unavailable: the account may remain signed in while the plan
  falls back to a still-valid cached grant or Free. Identity alone is not a
  fallback Pro authority.
