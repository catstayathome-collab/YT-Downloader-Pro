# YT Downloader Pro macOS Privacy Threat Model

## Document Control

| Field | Value |
| --- | --- |
| Status | Phase 1 engineering threat model |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-06 |
| Scope | macOS Swift 2.x local app only |
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

Out of scope until separate approval:

- Windows Python 1.8.x commercial work.
- Account, billing, entitlement, support, analytics, or sync backends.
- Production ECPay, Google OAuth, email, ticketing, or crash-reporting services.
- Public release publishing, repository visibility changes, or billing enablement.

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
| Local app to future backend | Not implemented | Operator services | Never send media activity by default; design requires separate approval |

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
| Future entitlement or support services collect media activity by default | `PRIVACY_DATA_MAP.md` forbids media URLs, titles, files, paths, cookies, and detailed diagnostics by default | Designed; implementation blocked |
| Cloud history sync exposes sensitive activity | Optional sync is postponed and requires explicit privacy design, deletion/export, retention, and legal review | Blocked |

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
- Full strict Swift 2.x suite with strict concurrency and warnings as errors.
- `git diff --check` or equivalent whitespace validation.
- Manual installed-app checks on clean supported Macs after Developer ID
  signing, notarization, stapling, and release packaging.
- Release-specific dependency and license inventory.
- A privacy review covering deletion/export, support reports, optional sync,
  backups, credential rotation, incident response, cancellation, refunds, and
  shutdown.
- `SUPPORT_REPORT_AND_DATA_REQUESTS.md` stays current with the implemented
  support-preview, local export, and local deletion behavior.

## 7. Open Launch Gates

The following remain blocked until fresh approval and dated evidence exist:

- Production checkout or recurring billing.
- ECPay submission or account configuration.
- Legal, tax, accounting, or payment-provider claims.
- Backend account, entitlement, support, analytics, or sync implementation.
- Collection of cloud download history.
- Public release publishing or repository visibility changes.
- Windows commercial implementation.
