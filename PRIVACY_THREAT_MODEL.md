# YT Downloader Pro macOS Privacy Threat Model

## Document Control

| Field | Value |
| --- | --- |
| Status | Phase 1 engineering threat model |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-06 |
| Scope | macOS Swift 2.x local app plus dormant staging authentication/entitlement path |
| Launch rule | Required controls must be tested before paid launch |

This document is an engineering review aid. It does not approve paid launch,
cloud history synchronization, production analytics, payment processing, support
vendors, or any external account action.

## 1. Scope

This threat model covers the current macOS Swift 2.x desktop application:

- URL analysis and download execution through bundled local helpers.
- Local queue, history, settings, thumbnails, and diagnostics.
- User-selected browser cookie modes.
- Local retry, recovery, pause, cancellation, and app relaunch behavior.
- Update checks and release presentation.
- A local-only mock authentication path with synthetic Google/Apple labels.
- A configuration-gated Google/Supabase PKCE staging adapter, signed
  entitlement verifier/cache, and policy bridge tested without external
  deployment.

Out of scope until separate approval:

- Windows Python 1.8.x commercial work.
- Production account, billing, support, analytics, or sync backends.
- Production ECPay, Google OAuth, email, ticketing, or crash-reporting services.
- Public release publishing, repository visibility changes, or billing enablement.

The mock performs no external call. The staging adapter can call Google and
Supabase only when an internal bundle contains validated public configuration
and the process uses exact staging mode. No external resource has been created
or deployed as part of this work. Apple remains a future provider. Identity is
not authorization; only a verified signed grant may change feature policy.

## 2. Protected Assets

| Asset | Why it matters | Current location |
| --- | --- | --- |
| Media URLs and playlist URLs | Reveal viewing interests and may include credentials or tokens | Input field, analysis results, jobs, diagnostics |
| Browser cookies and auth headers | Can grant account access or create account risk | Browser stores; passed to yt-dlp only by selected mode |
| Local output paths and filenames | Reveal identity, folder structure, and media choices | Jobs, helper arguments, diagnostics |
| Download history and queue state | Detailed behavioral history | Application Support snapshot |
| Thumbnails and titles | Reveal downloaded content even without URLs | Application Support thumbnail cache and jobs |
| Helper command output | May contain URLs, tokens, signatures, paths, or account hints | Progress parser, failures, diagnostics |
| Update URLs | Can direct the user to release pages or downloads | Update manifest and update UI |
| Mock restoration envelope | Contains a synthetic summary and opaque mock refresh credential | One device-only Keychain record per authentication environment |
| In-memory mock access token | Short-lived synthetic access material | `AccountSessionStore` memory only; never the Keychain envelope |
| Staging refresh credential and identity summary | Restores a Google/Supabase account and identifies the entitlement subject | Environment-scoped device-only Keychain record |
| Access token | Authorizes a short-lived entitlement refresh | Process memory only |
| Signed entitlement | Can grant Pro after verification | Separate environment-scoped device-only Keychain record |
| Entitlement signing private key | Authorizes server grants | Managed server secret store only; never the app/repository |

## 3. Trust Boundaries

| Boundary | Trusted side | Untrusted or higher-risk side | Required rule |
| --- | --- | --- | --- |
| User input to metadata analysis | Swift UI and store validation | Pasted or typed URL | Reject unsupported or credential-bearing media URLs before process launch |
| yt-dlp metadata to app state | Swift decoder and sanitizers | Helper stdout JSON | Accept only supported URLs and scrub retained media URL credentials |
| App state to persistence | Codable snapshot writer | Durable local disk | Scrub retained media URLs and sanitized failures before disk write |
| Legacy persistence to UI/runner | Recovery loader | Existing local snapshots | Scrub recovered jobs before publication or restart |
| Helper output to diagnostics | Parser and failure model | stdout, stderr, process errors | Redact cookies, tokens, signatures, query values, credentials, and output paths |
| Thumbnail URL to cache loader | Thumbnail cache validation | Remote image URL | Reject unsupported or credential-bearing remote URLs before fetch |
| Update manifest to UI opener | Update checker and release command | Remote manifest fields | Require HTTPS, expected platform, checksum, and credential-free URLs |
| Local app to staging backend | App-owned identity/entitlement adapters | Google, Supabase Auth, Edge Function | Exact allowlisted endpoints and callback; send identity/access material only, never media activity |
| Bundle to staging runtime | Strict config loader and verifier | Packaged JSON/resources | Internal channel only; publishable material only; reject symlinks, writable files, unapproved hosts, and secret patterns |
| Edge Function to app | Exact signed claim contract | Network response | Verify ES256 signature, `kid`, issuer, audience, subject, schema, times, features, state, height, and revision before adoption |
| Keychain to plan controller | Verified-entitlement store | Persisted compact token | Reverify after restart; account replacement/logout invalidates prior grant |

## 4. Threats And Controls

| Threat | Current control | Status |
| --- | --- | --- |
| A pasted URL embeds username or password and reaches yt-dlp | `MediaURLValidator` rejects unsupported or credential-bearing HTTP(S) URLs before analysis | Implemented and tested |
| yt-dlp metadata returns credential-bearing source or thumbnail URLs | Metadata decoding keeps only supported source/thumbnail URLs; store adoption scrubs injected analyzer output | Implemented and tested |
| A legacy or interrupted snapshot reintroduces unsafe media URLs | Persistence load, save, and store recovery scrub retained `sourceURL` and `sourceMetadata` values | Implemented and tested |
| A failed-job edit or retry reuses stale credential-bearing analysis | Failed edit apply and shared analysis adoption scrub retained URLs before retry start | Implemented and tested |
| A direct runner job bypasses UI/store validation | `DownloadRunner.prepareAndRun` rejects unsafe `DownloadJob.sourceURL` before helper launch | Implemented and tested |
| Diagnostics leak cookies, tokens, URL signatures, query values, credentials, or local output paths | `DownloadFailure` and `DiagnosticEvent` sanitize details and arguments before persistence | Implemented and tested |
| A malicious thumbnail URL causes credential leakage or local-file access | `ThumbnailCache` accepts only supported remote HTTP(S) URLs and rejects credential-bearing URLs | Implemented and tested |
| Update manifests steer users to unsafe release/download URLs | `UpdateChecker` and `UpdateReleaseCommand` require safe HTTPS URLs without userinfo | Implemented and tested |
| Local deletion controls accidentally delete media or expose local paths | `LocalDeletionDraft` and `LocalDeletionPreviewPresentation` preview deleted and retained categories, thumbnail cache names, and selected media file names without executing deletion or exposing full output paths | Implemented and tested |
| Account or entitlement service collects media activity | App-owned contracts contain no media fields; data map forbids URLs, titles, files, paths, cookies, history, and diagnostics | Implemented at client/local contract; external network inspection still required |
| Cloud history sync exposes sensitive activity | Optional sync is postponed and requires explicit privacy design, deletion/export, retention, and legal review | Blocked |
| Mock Keychain envelope is read by the wrong environment or duplicated | The vault appends the environment namespace, uses one `active-session` envelope, and uses device-only data-protection Keychain accessibility | Implemented and unit-tested; provisioned Developer ID host save/restore/delete evidence remains required |
| Mock credentials or complete identities leak into authentication diagnostics | Diagnostics accept a finite event enum only; credentials, account IDs, emails, Keychain data, and raw provider errors are prohibited | Implemented and tested |
| An environment typo exposes account controls or a provider surface | Only exact lowercase `mock` enables mock; only exact `staging` plus valid bundled config enables staging; every other combination is disabled | Implemented and tested |
| A cancelled or stale authentication operation overwrites newer state | Store operation ownership invalidates cancelled work and restores the prior stable state. Download lifecycle is not owned by authentication. | Store serialization is implemented and tested; active-download independence has manual smoke evidence only |
| OAuth callback is forged or replayed | Supabase Auth uses system-browser PKCE; configuration requires one exact custom-scheme callback and the adapter does not expose provider state | Implemented adapter and unit boundary; real staging callback evidence blocked |
| A bundled config contains a server/payment secret | Build checker and bundle verifier allow the exact public schema, scan all resources, redact reports, and forbid config in public builds | Implemented and tested |
| A forged, replayed, expired, wrong-account, or downgraded entitlement grants Pro | CryptoKit verifier checks ES256 signature and exact claims; controller enforces subject/time/revision and fails to cache or Free | Implemented and tested |
| A late entitlement response restores another account's Pro state | Bridge/controller operation IDs invalidate stale work; account replacement clears the old grant first | Implemented and tested |
| Access token persists to disk | Account store keeps access material in memory; Keychain envelope contains refresh credential only | Implemented and tested |
| Logout leaves a usable local grant | Auth and entitlement use separate scoped vaults; bridge clears entitlement and invalidates pending refresh | Implemented and tested; provisioned live Keychain evidence required |
| Signing key compromise produces valid malicious grants | Offline P-256 generation, server-only private key, rotation overlap, emergency fail-to-Free procedure | Runbook written; operational drill blocked |

## 5. Required Privacy Invariants

1. The app must not upload media URLs, titles, cookies, local paths, thumbnails,
   helper output, or download history to an operator service by default.
2. Any future support report must be user-reviewed and sanitized before it
   leaves the Mac.
3. Browser cookies are never automatic recovery. They require a user-selected
   per-job option and clear account-risk copy.
4. Retained jobs must not store credential-bearing media URLs, even when values
   come from helper output, injected analyzers, stale sessions, or legacy disk
   snapshots.
5. Diagnostics must prefer typed categories and sanitized details over raw
   helper output.
6. Update and release-opening flows must not accept credential-bearing,
   non-HTTPS, platform-mismatched, or checksum-invalid manifest data.
7. Paid feature gating must not weaken safety, privacy, diagnostics, update
   integrity, or recovery behavior for free users.

## 6. Verification Evidence To Maintain

Before a paid launch decision, keep current passing evidence for:

- Focused tests covering URL credential rejection and scrubbing at UI, metadata,
  store, persistence, recovery, retry/edit, thumbnail, runner, update, and
  diagnostics boundaries.
- Focused tests covering support-report, local export, and local deletion preview
  payloads and presentation contracts before support or data-request UI
  execution is enabled.
- Full strict Swift 2.x suite with strict concurrency and warnings as errors.
- Live Keychain save, relaunch restoration, scoped sign-out deletion, and
  disposable-namespace cleanup from a correctly provisioned Developer ID test
  host. Ad-hoc and plain SwiftPM processes are not acceptable evidence.
- `git diff --check` or equivalent whitespace validation.
- Manual installed-app checks on clean supported Macs after Developer ID
  signing, notarization, stapling, and release packaging.
- Release-specific dependency and license inventory.
- Written license review for the exact helper bundle, SBOM, notices, and
  source-delivery plan, tracked in `LICENSE_REVIEW_BRIEF.md`.
- A privacy review covering deletion/export, support reports, optional sync,
  backups, credential rotation, incident response, cancellation, refunds, and
  shutdown, with operational drills defined in `OPERATIONS_RUNBOOK.md` and
  public policy drafting gates defined in `PUBLIC_POLICY_DRAFTS.md`.
- `SUPPORT_REPORT_AND_DATA_REQUESTS.md` stays current with the implemented
  support-preview, local export, and local deletion behavior.
- Configured staging network inspection proving only approved identity and
  entitlement fields cross the boundary and no media activity is sent.
- Disposable Supabase migration/RLS tests, Google callback/branding validation,
  Edge Function secret provisioning, key rotation, account replacement, logout,
  server deletion, and project-pause drills.

## 7. Open Launch Gates

The following remain blocked until fresh approval and dated evidence exist:

- Production checkout or recurring billing.
- ECPay submission or account configuration.
- Legal, tax, accounting, or payment-provider claims.
- External staging/production account, entitlement, support, analytics, or sync
  deployment and operational verification.
- Collection of cloud download history.
- Public release publishing or repository visibility changes.
- Windows commercial implementation.
