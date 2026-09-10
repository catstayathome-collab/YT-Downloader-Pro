# YT Downloader Pro Support Reports And Data Requests

## Document Control

| Field | Value |
| --- | --- |
| Status | Phase 1 support privacy design |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-09-07 |
| Scope | macOS Swift 2.x local app, support report preview, export, and deletion rules |
| Launch rule | Must be implemented and tested before paid support or account services |

This document is an engineering runbook for privacy-safe support and user data
requests. It does not approve a support vendor, production email, account
backend, cloud history sync, payment processing, or any external submission.

## 1. Goals

- Give users a support path that does not silently upload download activity.
- Keep media URLs, titles, local paths, cookies, tokens, and raw helper output
  out of support tickets by default.
- Define what a user can preview, export, delete, or withhold before data leaves
  the Mac.
- Preserve enough local diagnostic context to troubleshoot failures without
  collecting unnecessary personal data.
- Create testable acceptance criteria for future Help and Settings support UI.

## 2. Non-Negotiable Rules

1. Support submission is always user initiated.
2. The app shows the exact report payload before submission or file export.
3. Optional fields start disabled and can be removed before submission.
4. Source URLs, video IDs, playlist IDs, titles, thumbnails, output paths,
   browser profile names, cookies, authorization headers, PO Tokens, signatures,
   full stdout, full stderr, screenshots, and downloaded files are excluded by
   default.
5. Payment support must use provider or internal order references. The app and
   support staff must never request full card data, bank credentials, passwords,
   Google authorization codes, cookie exports, or identity-document images.
6. Security, privacy, copyright, cancellation, incorrect-charge, and account
   recovery reports bypass paid priority rules.
7. Local deletion must not delete downloaded media unless the user chooses a
   separately named media-file deletion action.

## 3. Support Report Payload

Current local foundation:

- `SupportReportDraft` builds a macOS Swift 2.x preview payload for user review.
- The default preview includes typed environment and failure context, but leaves
  optional source URL, title, format, screenshot, contact, diagnostic-export,
  and media-file fields disabled.
- The preview includes a local `bypassesPaidPriorityRules` routing flag for
  privacy, security, copyright, cancellation, incorrect-charge, and
  account-recovery categories.
- Support-specific diagnostic excerpts receive an additional local redaction pass
  so URLs, local paths, selected media titles, cookies, and tokens do not appear
  in the default encoded payload.
- No submission endpoint, support vendor, email flow, account backend, or upload
  action is implemented by this model.

### Included by default

The first macOS Swift 2.x support report may include:

- User-selected category.
- User-written subject and message.
- App version, release channel, macOS version, CPU architecture, and locale.
- Local incident identifier generated for the report.
- Normalized error category and recovery level when a job failure is selected.
- Sanitized diagnostic excerpt, limited to the chosen incident and bounded by
  line count or byte size.

### Optional and separate opt-in

The user may add these only through separate controls and final preview:

- Source URL or playlist URL needed to reproduce a downloader failure.
- Media title or selected format identifier.
- Larger sanitized diagnostics export.
- Screenshot selected by the user.
- A contact email when the current flow is anonymous or unauthenticated.

The UI copy for URL or title opt-in must state that the field can reveal viewing
or download activity.

### Never accepted

The support form must reject or remove:

- Browser cookie files, exported cookies, authorization headers, PO Tokens,
  account passwords, and Google authorization codes.
- Full payment card numbers, CVV values, bank credentials, and identity-document
  images.
- Downloaded media files or partial media fragments.
- Raw helper command logs that have not passed local sanitization.

## 4. Local Export

Current local foundation:

- `LocalDataExportDraft` builds a macOS Swift 2.x preview payload for a local
  export manifest, selected queue/history records, sanitized settings,
  thumbnail cache references, and bounded diagnostic excerpts.
- The default export preview scrubs retained job media URL credentials and
  removes output media paths, browser-cookie mode, security-scoped bookmark
  data, and output-folder display paths before encoding.
- Thumbnail references expose only local cache file names, not remote thumbnail
  URLs or embedded image data.
- No file writer, submission endpoint, support vendor, email flow, account
  backend, or upload action is implemented by this model.

The app should expose a local export action before any cloud account or support
backend exists. Export is useful for self-service troubleshooting and future
data-access requests.

The export package contains only local app records selected by the user:

- `manifest.json` with app version, export time, schema version, and selected
  sections.
- Queue and history records after credential-free media URL scrubbing.
- App settings excluding security-scoped bookmark binary data.
- Thumbnail references without embedding remote URLs by default.
- Sanitized diagnostics selected by incident or date range.

The default export excludes downloaded media, browser cookies, payment records,
Keychain tokens, security-scoped bookmarks, full diagnostic directories, and
screenshots. If future account, billing, support, or sync services are approved,
server-side export becomes a separate authenticated backend workflow and must
not be merged silently with local export.

## 5. Local Deletion

The macOS app must provide separate deletion actions with distinct labels:

| Action | Deletes | Does not delete |
| --- | --- | --- |
| Clear completed history | Completed local job records and related thumbnails | Downloaded media files, settings, diagnostics |
| Clear failed/cancelled history | Failed or cancelled job records and related thumbnails | Downloaded media files, settings, diagnostics |
| Clear diagnostics | Rotating local diagnostic files | Queue/history records, downloaded media |
| Reset settings | Local preferences and output-folder bookmark | Queue/history records, downloaded media |
| Delete selected media file | The user-selected downloaded file after confirmation | Other history, diagnostics, unrelated files |

Deletion of an active, paused, or retryable job follows the controlled recovery
ladder ownership rules. The app deletes only files it can prove belong to that
job and leaves user-owned downloaded media untouched unless the user explicitly
selects the media-file action.

## 6. Future Backend Requests

Before paid accounts, support portals, history sync, analytics, or billing are
implemented, the project needs an approved user-request workflow for:

- Account data export.
- Account deletion.
- Subscription cancellation and refund handling.
- Support ticket deletion or retention limitation.
- Billing record retention required for tax, disputes, refunds, or fraud review.
- Backup expiry and restore exclusion after deletion.

Backend deletion requests must preserve only records required for legal, tax,
payment-dispute, security, abuse-prevention, or accounting obligations.
Preserved records need purpose, access control, retention period, and audit
coverage.

## 7. Verification Checklist

Before paid launch or support submission is enabled:

- Unit tests prove default support payloads exclude media URLs, titles, paths,
  cookies, tokens, screenshots, downloaded files, raw helper output, and full
  diagnostics.
- Sanitization tests cover URL credentials, query values, local paths, cookies,
  tokens, signatures, auth headers, and yt-dlp output/path arguments.
- UI or presentation tests prove optional report fields start disabled and the
  final preview shows every field selected for submission.
- Local export tests prove retained job URLs are credential-free and bookmarks,
  Keychain tokens, cookies, media files, remote thumbnail URLs, local output
  paths, and full diagnostics are excluded by default.
- Deletion tests prove clearing history removes local job records and thumbnails
  without deleting downloaded media.
- Support-routing tests prove privacy, security, copyright, cancellation,
  incorrect-charge, and account-recovery categories do not depend on Pro status.
- Manual clean-Mac testing confirms exported files contain only the selected
  sections and can be inspected without network access.

## 8. Open Gates

The following remain blocked until fresh owner approval and dated evidence:

- Selecting or configuring a production support vendor.
- Sending email or submitting test reports to an external service.
- Implementing account, billing, entitlement, analytics, or sync backends.
- Collecting cloud history or diagnostics.
- Enabling paid support, production checkout, or recurring billing.
- Publishing a public release or changing repository visibility.
