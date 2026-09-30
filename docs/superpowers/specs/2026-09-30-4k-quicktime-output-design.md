# 4K And QuickTime Output Repair

Status: written specification approved by the owner on 2026-09-30;
Task 1 execution approved. Scope: macOS Swift only. No payment,
deployment, release or Windows changes.

## Intent And Evidence

Show all usable resolutions while preserving Free/Pro policy. Default to
QuickTime-compatible output; offer original encoding as an explicit alternative.
Do not trade away the selected resolution silently.

Source investigation found H.264-only filtering in MediaOptionsSheet and
QuickTimeMP4Compatibility, and matching selectors in YouTubeStrategy. These
were introduced by df6ef88. On 2026-09-29 the bundled yt-dlp default client
listed gsT6eKsnT0M formats 313 (VP9) and 401 (AV1) at 3840x2160, while H.264
137 stopped at 1920x1080. web_embedded returned a missing-URL warning and only
360p in that session. These are historical observations, not guaranteed future
YouTube responses. No browser cookies were used.

## Options And Presentation

Add a Codable MP4 output mode: quickTimeCompatible (default) and originalEncoding.
Decode absent fields in old settings/jobs as quickTimeCompatible. Unknown values
must fail safely rather than silently select a different mode. MP3 ignores the
mode. Persist the choice per job and in defaults; editing a queued job changes
only that job. Localize UI in all existing supported languages.

Keep all usable video formats visible; use the existing FeaturePolicy/menu locks
for Free <=720p and Pro high resolutions. Encoding mode must never confer Pro.
Both selection and execution boundaries enforce policy, including best quality,
retry, batch, resumed and previously persisted jobs.

The media options and default settings expose a two-option picker. Compatible
mode shows a brief conversion notice when the selected source requires it.
Original mode indicates that QuickTime playback is not guaranteed. No unsupported
format is silently substituted with a lower resolution.

## Analysis Strategy

Keep bounded attempts. For a single-video no-cookie analysis, compare at most
two successful candidate results (explicit embedded and default client), even
if the first is low resolution: success alone does not prove completeness.
Choose one whole result, preferring the highest usable video resolution, then
the number of usable video formats; ties retain the first result. Do not merge
format IDs from different client responses or drop subtitle/audio metadata by
mixing partial records. Failure of the second probe may retain a usable first
result; cancellation must never trigger a second probe.

Persist a bounded internal client-strategy identifier alongside analysis/job
selection so execution requests the same strategy. Old jobs retain legacy
behavior. Retry must revalidate explicit format availability, not download an
unrequested lower resolution. Playlist expansion is unchanged. Cookie-enabled
analysis retains the existing opt-in one-attempt behavior; no automatic cookie
access or PO-token acquisition is added.

## Download And Conversion

Separate source format selection from target compatibility. QuickTime-compatible
mode may select VP9/AV1 sources, without the H.264-only selector. Preserve explicit
video/audio selections. Do not upscale or downscale the source.

After yt-dlp succeeds, inspect actual streams using bundled ffprobe. Use a typed
conversion decision, not filename extensions. Conservative copy eligibility is
H.264 with compatible pixel format plus AAC in MP4; validated HEVC with supported
pixel format and hvc1 signaling may also be copied. Other video sources require
HEVC encoding; incompatible audio requires AAC encoding. Supported streams may
be copied independently. Preserve display dimensions, frame timing, rotation and
color metadata; reject inputs whose HDR/color handling cannot be preserved by
the implemented path rather than silently changing their appearance.

Use bundled FFmpeg and a capability-checked encoder. Prefer VideoToolbox HEVC
when available; allow a verified bundled software HEVC encoder as fallback.
If neither can produce the required output, provide a localized actionable
failure; never downgrade to 1080p or claim original output is compatible.
Encoder settings and hardware/software quality parity require fixture tests
and visual inspection before packaging acceptance, not an arbitrary bitrate
assumed to preserve quality. Re-encoding is lossy and must not be called lossless.

Original mode copies original video/audio streams into MP4 where supported.
If muxing those streams is unsupported, report a format error rather than
silently converting or producing a differently suffixed file. Both modes must
preserve requested subtitle, thumbnail and metadata behavior; MP4 embedded
subtitle conversion is separate from video encoding, and sidecar SRT is retained.

## Runner And File Safety

Run probing/conversion within DownloadRunner's owned process lifecycle using
existing process abstractions. Keep the output directory security scope and
filename reservation until completion. Use unique job-owned intermediate files
in the output filesystem, bounded to the reserved basename, so final publication
can be atomic and cannot overwrite another job or an existing media file.

Only report completed after successful probe of the final output: video exists,
dimensions match the selected source display dimensions, required audio exists,
and compatible mode meets its codec/pixel format/signaling checks. Missing output,
disk-full, probe failure and conversion failure must not yield completed.

Conversion is postprocessing with measured FFmpeg progress, not a fake download
percentage. It occupies the job's existing scheduler slot. Pause stays disabled
during merging/postprocessing as in current behavior. Cancel terminates the owned
process, waits for exit, and removes only owned temporary artifacts. Quit/crash
recovery restarts incomplete conversion from a validated retained source; never
appends to an interrupted encode. Failure preserves enough owned source state
for retry; cleanup must not remove unrelated or already published media.

## Implementation Boundaries

- Models: DownloadOptions, MediaAnalysis and any client-strategy persistence.
- Presentation: MediaOptionsSheet, SettingsView, localized resources and locks.
- Analysis: MetadataProbe and YouTubeStrategy, with fake process coverage.
- Output: small typed compatibility/conversion planner and probe decoder.
- Lifecycle: DownloadRunner, progress parsing, reservation and recovery tests.
- Tests: existing OptionsPresentationTests, YouTubeStrategyTests,
  MetadataProbeTests and runner/storage suites, plus conversion fixtures.

Do not weaken URL validation, cookie consent, entitlement enforcement or process
ownership. Keep payment-related files untouched.

## Acceptance And TDD Order

1. RED: real-shaped 2160p VP9/AV1 fixtures appear in menus; Free locks remain;
   old jobs decode to compatible mode. Implement options/presentation.
2. RED: low-resolution success still probes the second client; cancellation,
   total failures, cookie opt-in and matching download strategy are preserved.
3. RED: source selectors no longer silently cap Pro at H.264 resolution;
   explicit selections and Free execution constraints remain enforced.
4. RED: typed FFprobe decisions for copy, video/audio conversion and unsupported
   color cases. Validate local synthetic 4K SDR outputs with actual bundled tools.
5. RED: conversion failure/cancel/quit/restart/disk-full cannot complete or delete
   unrelated files; subtitles/metadata and duplicate filenames survive.
6. Full strict Swift suite and packaging checks. Inspect internal-test UI in
   supported locales, Free and Test Pro. Fresh probe of the supplied video;
   download a 4K test result, check dimensions/streams, open in QuickTime and
   verify playback/seek/audio. Compare original mode. Network or media restrictions
   must be reported explicitly; synthetic tests do not replace real playback QA.

No public release until this acceptance passes. A separate implementation plan
will split reviewable commits after this written specification is approved.
