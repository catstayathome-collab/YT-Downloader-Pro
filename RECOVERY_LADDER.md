# YT Downloader Pro Controlled Recovery Ladder

## Document Control

| Field | Value |
| --- | --- |
| Status | Phase 1 reliability architecture; implementation review required |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-08-26 |
| Initial client | macOS Swift 2.x |
| Scope | Local yt-dlp-based analysis and download recovery |

This document defines bounded, observable recovery behavior for upstream media
failures. It is not authorization to bypass access controls, fetch content the
user may not access, or send user data to an external download service.

## 1. Objectives

- Recover automatically from genuinely transient failures without retry loops.
- Reanalyze expired media URLs before retrying a failed transfer.
- Keep the selected quality and format unless the user explicitly approves a
  replacement.
- Preserve safe partial files for resume, while cleaning reservations and temp
  files when ownership is known.
- Keep URLs, browser cookies, PO Tokens, local paths, and media off operator
  servers and out of diagnostics.
- Produce a localized, actionable final error when recovery is exhausted.
- Make every strategy transition testable and visible in sanitized diagnostics.

## 2. Current Swift 2.x Baseline

The existing implementation already provides a useful first layer:

- The first uncookied YouTube attempt selects `web_embedded` explicitly.
- A qualifying 403 or client-validation failure may make one bounded retry
  using the bundled yt-dlp default client selection.
- Browser cookies are used only when the user selects Chrome or Safari.
- A retry after a failed download reanalyzes the video rather than reusing stale
  format URLs.
- Downloads use continuation and no-overwrite behavior.
- Error categories distinguish authentication, client validation, unavailable
  formats, disk, permissions, helper failures, and post-processing failures.
- Diagnostic arguments and text redact cookies, authorization values, tokens,
  signatures, sensitive flags, and URL query values.

This baseline must remain covered while the additional levels below are added.

## 3. Recovery Invariants

These rules apply at every level:

1. No infinite retry, client-switch, provider-switch, or update loop.
2. No automatic use of browser cookies. Cookie use requires a user-selected
   per-job option and a clear explanation of account risk.
3. No silent downgrade from the selected format or resolution. If the exact
   selection is unavailable, pause and ask the user to choose an alternative.
4. No retry for invalid URLs, removed/private/DRM media, output permission
   denial, full disk, or an unusable bundled helper until the cause changes.
5. No URL, cookie, token, media, title, path, or download history is uploaded to
   YT Downloader Pro or an unreviewed third party as part of recovery.
6. A retry must not allocate a second output name for the same job. The job
   retains its reservation and only releases it on terminal cleanup.
7. Cancellation deletes only files proven to belong to the job. Pause retains
   resumable partial data.
8. Each attempt records a sanitized strategy identifier, failure category,
   elapsed time, and transition reason. It never records secret arguments.
9. Legal, platform-policy, privacy, and licensing stop conditions override
   technical recoverability.

## 4. Recovery Levels

### Level 0: Preflight

Before analysis or download:

- Resolve exactly one bundled path for yt-dlp, FFmpeg, FFprobe, and the approved
  JavaScript runtime/provider components.
- Verify each required executable by actually running its version command with
  a timeout; existence and executable bits alone are insufficient.
- Verify the output security-scoped bookmark, write permission, free disk
  estimate when available, network reachability category, and system clock.
- Verify that the selected strategy is enabled by the signed local policy.

Failure is terminal until corrected for missing helpers, incompatible
architecture, invalid signatures, output permission, disk capacity, and invalid
input. The UI must describe the local remedy instead of surfacing raw yt-dlp
stderr.

### Level 1: Standard Local Attempt

- Analyze with the reviewed default strategy.
- Resolve exact format identifiers and expected post-processing.
- Download with resume enabled and no overwrite.
- Use only bundled, version-checked helpers.
- Keep browser-cookie mode `none` unless the user explicitly selected it.

For the current release, the first uncookied YouTube strategy remains
`web_embedded`. This is an implementation detail controlled by a signed policy,
not a permanent product promise.

### Level 2: Transient Same-Strategy Retry

Retry the same strategy only for a classified transient event:

- connection reset, timeout, temporary DNS failure, or interrupted transfer;
- HTTP 500, 502, 503, or 504;
- HTTP 429 only after honoring `Retry-After` when present and applying the
  queue-wide cooldown policy.

Use at most two same-strategy retries with exponential backoff and jitter. The
initial proposed schedule is approximately 2 seconds and 6 seconds, capped by
the response's longer valid retry instruction. A cancelled or paused job exits
the wait immediately.

Do not classify 401, 403, private media, removed media, unavailable format,
disk, permission, helper, or post-processing errors as generic transient
failures.

### Level 3: Fresh Reanalysis

Use fresh reanalysis when a signed media URL may have expired or a transfer
receives a 403 after making progress:

1. Stop using all previously resolved media URLs.
2. Preserve the job's owned partial file and output-name reservation.
3. Run metadata analysis again under the same approved strategy.
4. Confirm that the selected format identity or an exactly equivalent format
   remains available.
5. Resume only when compatibility is confirmed.

If the exact selection is unavailable, transition to Level 8. Never infer that
720p is an acceptable substitute for a paid 4K selection or that another codec
is equivalent without policy and user confirmation.

### Level 4: Reviewed Client Fallback

For a classified YouTube client-validation or 403 failure, make at most one
client transition. The current sequence is:

1. explicit `web_embedded`;
2. bundled yt-dlp default client selection, with no forced extractor client.

The fallback is allowed only without browser cookies unless a separately tested
cookie policy explicitly permits the combination. A failed fallback does not
cycle back to the first client.

Client order must live in a signed, versioned compatibility policy with a
kill-switch. Changes require canary evidence, regression tests, and release
notes; they are not silently fetched from arbitrary web content.

### Level 5: Signed Toolchain Compatibility Recovery

If diagnostics identify a known incompatible bundled yt-dlp or helper version:

- Check the platform-specific signed update manifest.
- Offer or perform only the update behavior previously selected by the user.
- Verify checksum, signature, architecture, version output, and rollback
  metadata before activation.
- Keep the previous known-good toolchain for rollback.
- Restart analysis after activation; do not swap executables inside a running
  download process.

Never download an executable from a diagnostic message, media page, mirror, or
unreviewed release URL. A tool update consumes one recovery transition, not a
new unlimited attempt budget.

### Level 6: Optional PO Token Provider Strategy

This level is experimental and disabled by default until legal, privacy,
licensing, signing, and reliability reviews pass.

Current yt-dlp guidance recommends a PO Token Provider plugin rather than
manual token copying because some tokens are bound to video/session context.
The currently suggested technical candidate is a local provider supplying the
required GVS token for the `mweb` client. This is not a guarantee of stability
and must not be treated as an official YouTube interface.

Enablement requirements:

- The provider and all transitive code are audited, pinned, bundled, signed,
  version-compatible, and included in the Software Bill of Materials.
- Provider operation remains local. Tokens, cookies, URLs, and account data are
  not uploaded to the operator or provider author.
- A startup health check proves the provider can execute without opening a
  listener to untrusted networks.
- A remote signed kill-switch can disable the strategy without disabling local
  downloads that do not need it.
- The provider receives at most one attempt per job after prior reviewed levels
  fail with an eligible category.
- Canary monitoring shows a materially better success rate without increased
  account, privacy, or block risk.

Provider failure falls forward to an actionable error or Level 8. It never
causes repeated token generation or automatic browser-cookie access.

### Level 7: Explicit Authenticated-Media Path

When analysis indicates that authentication may legitimately be required:

- Explain that browser-cookie use may expose the user's signed-in YouTube
  session to the local yt-dlp process and may carry account restrictions.
- Require the user to edit the individual job and select one supported browser.
- Do not export, copy, upload, retain, or print cookie contents.
- Make one analyzed attempt using that selection.
- Never imply that cookies authorize copyright infringement or bypass DRM.

This path is not automatic recovery and is not enabled for content the product
policy refuses. Cookie mode must not be combined indiscriminately with every
client or PO Token provider.

### Level 8: User-Approved Format Reselection

If the requested format is no longer available:

- Pause the job with `formatReselectionRequired`.
- Show newly analyzed compatible formats and the reason for the change.
- Preserve the original choice for comparison.
- Require the user to confirm a replacement before creating another attempt.
- Enforce the current Free/Pro entitlement at the command boundary.

The application must never silently lower quality to make the success metric
look better.

### Level 9: Controlled Failure And Support Export

When the attempt budget is exhausted:

- Stop the job and retain safe resumable partial data unless the user cancels.
- Present the localized category, useful next action, last safe strategy label,
  and whether retrying later is reasonable.
- Offer a user-reviewed support report containing only approved diagnostics.
- Keep URLs, titles, paths, cookies, tokens, and full raw stderr excluded by
  default. Any optional attachment requires separate opt-in and preview.

## 5. Attempt Budget And Circuit Breakers

Initial policy values, subject to canary tuning:

| Control | Maximum |
| --- | ---: |
| Total automatic network executions per job | 5 |
| Same-strategy transient retries | 2 |
| Fresh reanalysis transitions | 1 |
| Client fallback transitions | 1 |
| PO Token provider attempts | 1 |
| Automatic toolchain activations during a job | 1 |
| User-authenticated attempts | 1 after explicit selection |

The total-job limit wins when individual limits would sum to more than five.
User-initiated retry starts a new bounded recovery run after reanalysis, while
retaining a lifetime retry count for diagnostics.

HTTP 429 activates a queue-wide host circuit breaker. New jobs wait rather than
amplifying traffic. The UI shows the cooldown state, and cancellation remains
available. Repeated 429, account warnings, or provider health failures disable
the relevant strategy until a later policy check or app restart.

## 6. Failure Classification Matrix

| Failure | Automatic action | User action |
| --- | --- | --- |
| Timeout/reset/5xx | Level 2 within budget | Retry later after exhaustion |
| 403 before transfer | Level 4 if eligible | Review error or auth option |
| 403 after progress | Level 3, then eligible Level 4 | Keep partial and retry later |
| 429 | Honor cooldown; bounded retry | Wait; do not add account cookies blindly |
| Requested format missing | Level 8 | Select replacement |
| Login required | Stop before Level 7 | Explicitly choose reviewed browser cookies |
| Private/removed/DRM/region policy | Stop | No technical bypass offered |
| Helper missing/unexecutable | Level 0 failure; optional Level 5 | Install signed app update |
| Disk full/output denied | Stop | Free space or choose/authorize folder |
| FFmpeg/post-processing failure | Preserve inputs; classify helper/output cause | Retry after remedy |
| Provider unhealthy | Disable Level 6 | Use standard path or retry later |

## 7. Observability And Privacy

Each sanitized recovery event may contain:

- random local job identifier;
- app, policy, and bundled tool versions;
- stage and strategy identifier;
- normalized failure category and HTTP class;
- attempt ordinal, elapsed time, and transition decision;
- architecture, macOS major version, and locale when the user exports a report.

It must not contain the source URL, query string, video ID, title, channel,
output path, browser profile path, cookies, headers, PO Token, media URL,
signature, full command, or unfiltered stdout/stderr. Local diagnostics follow
the retention and deletion rules in `PRIVACY_DATA_MAP.md`.

## 8. Test Requirements

Before enabling a new level, add deterministic fixtures for:

- 403 during metadata analysis and one-way client fallback;
- 403 after approximately one-third of a transfer, followed by fresh analysis;
- expired signed URL with successful exact-format resume;
- missing exact format requiring user reselection;
- 429 with `Retry-After`, queue-wide cooldown, cancellation, and restart;
- timeout and 5xx backoff with strict attempt caps;
- browser-cookie path never selected automatically;
- provider unavailable, malformed response, timeout, and kill-switch behavior;
- helper signature/version/architecture failure;
- disk full, lost security scope, pause, cancel, and app relaunch;
- diagnostics proving no URL, cookie, token, signature, or path leakage;
- no silent quality downgrade and Free/Pro enforcement at process arguments.

Canary testing uses owner-controlled or expressly licensed media fixtures. Daily
monitoring must avoid high traffic, account-risky behavior, and copyrighted
media retention.

## 9. Rollout And Rollback

1. Implement the classifier and attempt budget independently of new clients.
2. Preserve and expand current `web_embedded` and default-client tests.
3. Add signed-policy plumbing with all new strategies disabled.
4. Enable one strategy for local tests, then a small opt-in canary cohort.
5. Compare success, latency, 429, account-warning, and privacy signals.
6. Roll back automatically when thresholds are exceeded.
7. Promote only after a documented review and owner approval.

The policy manifest must be signed and must never contain executable code,
tokens, cookies, or arbitrary command-line fragments.

## 10. References

- [yt-dlp PO Token Guide](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide)
- [yt-dlp README](https://github.com/yt-dlp/yt-dlp/blob/master/README.md)
- [YouTube Terms of Service](https://www.youtube.com/t/terms)
- [YouTube API Services Developer Policies](https://developers.google.com/youtube/terms/developer-policies)
