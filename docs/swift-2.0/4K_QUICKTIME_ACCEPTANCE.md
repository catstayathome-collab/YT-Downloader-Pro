# 4K QuickTime Acceptance

Task 6 evidence, 2026-10-04. Internal macOS testing only. This is not a
public-release approval. Unchecked items below remain open acceptance gates.

## Candidate And Scope

- Branch: `codex/supabase-staging-integration`.
- Initial candidate: `1a7b1aa`, clean tree at build time.
- Follow-up repair: `1684ae7`, clears stale transfer metrics during postprocessing.
- Final reviewed source: `0c1d935`, remuxes progressive WebM sources and rejects
  missing explicitly selected audio. Only this evidence document was untracked
  during the final build; tracked source was clean.
- Version/channel: 2.0.1 / internal-test / arm64 / ad-hoc signing.
- No public update manifest, tag, release, account or payment configuration changed.
- Test destination: `/tmp/ytdp-task6-live`; existing user downloads were not overwritten.

## Automated Evidence

- Initial public-flavor strict suite: 643 tests, 3 opt-in skips, zero failures.
- Initial internal-flavor build suite: 649 tests, 3 opt-in skips, zero failures.
- Bundled media opt-in suite: 14 tests, zero failures. Real VideoToolbox conversion,
  portrait rotation, VFR timestamps, HDR copy/rejection, subtitles and artwork are
  covered by `MP4OutputToolIntegrationTests` and the real runner integration test.
- Regression RED: `DownloadStoreTests.testPostprocessingClearsDownloadMetricsBeforeReceivingConversionProgress`
  failed five assertions (old fraction, bytes, speed and ETA survived the phase change).
- After repair: public-flavor strict suite 644 tests, 3 opt-in skips, zero failures.
  The regression additionally verifies measured conversion progress and that a
  restored job does not reuse a stale conversion fraction.
- Persistence, Free policy at source/final publication, batch policy, retry,
  cancellation, duplicate-name and owned-workspace behavior have automated coverage.
  These checks are not a claim that every equivalent UI path was manually exercised.
- Independent complete-diff review found two P2 defects: progressive WebM did not
  produce the required owned `source.mp4`, and an explicitly selected audio track
  could be absent without failing. Both regressions were reproduced before fixes
  (two tests, four failures). After repairs the full strict suite passed 646 tests
  with three opt-in skips, the bundled hardware suite passed 14 tests, and the
  final internal-flavor build suite passed 652 tests with three skips; all had zero
  failures. The exact argument-template test was updated for the new remux option.
- The actual bundled yt-dlp also remuxed a local progressive VP9/Opus WebM clip
  into MP4 without transcoding, retaining 3840 x 2160 dimensions and both codecs.
  The test-only file-URL flag was used only for this CLI fixture, not added to App
  arguments. Its final ffprobe confirmed an MP4 container.
- SwiftPM cache and macOS CoreData/XPC diagnostics occurred in the test environment;
  they did not cause test failures. Compiler warnings remain errors in these runs.

Reproduce strict tests from the worktree:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/ytdp-clang-cache \
  swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

env YTDP_RUN_MP4_TOOL_INTEGRATION=1 CLANG_MODULE_CACHE_PATH=/tmp/ytdp-clang-cache \
  swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors \
  --filter 'MP4Output|DownloadRunnerTests.testRealBundledRunnerConverts4KAndPreservesSubtitlesAndMetadata'
```

VideoToolbox integration needs host encoder access, not the restricted execution
sandbox. The bundled tools were not updated during this task.

## Supplied Video

Video ID: `gsT6eKsnT0M`. Both fresh default-client and web-embedded analysis,
without cookies, returned 2160p VP9 (313) and AV1 (401). The built App's Test Pro
sheet selected 2160p WebM with QuickTime-compatible output. This is an actual
network download through the App, not the synthetic downloader fixture.

| Measurement | Source retained for comparison | Compatible published output |
| --- | --- | --- |
| Video | VP9 / vp09 | HEVC / hvc1 |
| Dimensions | 3840 x 2160 | 3840 x 2160 |
| Pixel format / color | yuv420p / BT.709 | yuv420p / BT.709 |
| Audio | Opus, 48 kHz, stereo | AAC, 48 kHz, stereo |
| Duration | 333.114 seconds | 333.114 seconds |
| Bytes | 291952642 | 151373148 |

The completed job took about 359 seconds from recorded start to completion;
this includes download, probes, conversion and final verification, not encoder
time alone. The private workspace and reservation marker were removed on success.
A second test job was cancelled during postprocessing: its private workspace was
removed while the first completed MP4 and the comparison copy remained intact.

The original-mode App job completed in about 187 seconds and persisted
`originalEncoding` in the queue. Its numbered output `(1).mp4` retained VP9/Opus,
3840 x 2160, 333.114 seconds and 291952642 bytes. QuickTime displayed its
incompatible-media warning; the prompt was cancelled. No claim of original-mode
QuickTime playback is made. Both success paths removed their owned workspace.

QuickTime opened the compatible output, entered playing state, sought to 166
seconds and continued to 174 seconds with visible video frames. A 10-second AAC
decode near 160 seconds succeeded: mean -17.7 dB, peak -3.1 dB. This establishes
decodable non-silent audio, not subjective listening or lip-sync approval.

A 90-frame, 3-second source/output comparison near 160 seconds measured SSIM
0.982924 (timestamps aligned only for measurement). The observed QuickTime frame
was correctly oriented and nonblank. Neither observation proves visually lossless
quality over the complete video; the setting remains a lossy HEVC conversion.

## UI Evidence And Remaining Gates

- [x] Traditional Chinese Test Pro sheet exposes 2160p and compatible-mode notice.
- [x] Chinese, English and Japanese settings change immediately, including encoding notice.
- [x] Japanese media sheet shows localized options and 2160p.
- [x] Actual compatible download, final ffprobe, QuickTime play and seek.
- [x] Actual postprocessing cancellation cleans only the test workspace.
- [x] Original-mode App download and QuickTime compatibility observation.
- [x] Final rebuilt candidate smoke test, Free locked menu and English media sheet.
- [ ] Human listening, sync and quality approval of the delivered sample.
- [x] Complete-branch independent review and required regression repairs.

The final rebuilt App analyzed the supplied video in Free/English: 720p was
selected and 1080p/1440p/2160p entries showed `lock.fill` with `Requires Pro`.
Clicking 2160p opened the local plan comparison; closing it retained 720p and
created no queue job. The initial Traditional Chinese, Test Pro and original
output-folder preferences were restored after testing. Native macOS panels still
use the operating system's Japanese language, independent of the App locale.

## Delivered Internal Artifact

- App: `dist/swift-2.0/internal-test/YT Downloader Pro 2.app`.
- ZIP: `dist/swift-2.0/internal-test/YT-Downloader-Pro-2.0.1-macOS-arm64-internal-test.zip`.
- ZIP SHA-256: `dafa1e9b9556f97e2e8d534a1df389cdd3e4fe0bf7278058b550d472344f441f`.
- Verification: `swift-2.0-internal-test-bundle-report.json` reports `ok: true`,
  expected version 2.0.1, channel internal-test and arm64 executables.
- Build command: `./scripts/build_swift_2.sh --app-channel internal-test --version 2.0.1 --architectures arm64 --unsigned-test --sbom-created 2026-10-04T04:12:00Z`.
- Source commit: `0c1d935`; the later evidence commit changes documentation only.
- Real network playback/download observations preceded the last boundary repairs;
  the final candidate was rebuilt, regression-tested and UI-smoke-tested, not
  represented as a second complete real-network conversion.

Release-specific exclusions: clean-Mac installation, Developer ID/notarization,
Intel support and external-volume compatibility are not established here. The
current atomic publication uses hard links: filesystems without them fail closed.
Do not describe exFAT as supported without a separate implementation and test.
The bundled yt-dlp 2026.07.04 emits an age warning; successful current tests do
not guarantee future YouTube availability.

## Local Evidence Locations

Logs under `/tmp`: `ytdp-task6-full.log`, `ytdp-task6-build.log`,
`ytdp-task6-hardware.log`, `ytdp-task6-red.log`, `ytdp-task6-final-tests.log`,
`ytdp-task6-audio.log`, `ytdp-task6-ssim.log`, `ytdp-task6-final-build.log`.
Final review logs: `ytdp-task6-review-red.log`, `ytdp-task6-review-green.log`,
`ytdp-task6-review-hardware.log`, `ytdp-task6-reviewed-build.log`, and
`ytdp-task6-progressive-remux.log`.
Temporary logs/media can be removed by macOS; the sanitized facts above are the
durable record. Do not commit raw YouTube metadata, signed media URLs or user data.
