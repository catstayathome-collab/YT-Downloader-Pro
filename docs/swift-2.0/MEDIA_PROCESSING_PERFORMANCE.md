# Media Processing Performance

2026-10-04. Bounded macOS Swift 2.0.1 optimization, internal testing only.
This does not authorize a public release, account changes or payment deployment.

## Problem And Decision

`DownloadRunner.probeMedia` performs full `ffprobe -count_frames` scans before
processing and before publication. The previous default software-decoder threading
made these scans a substantial part of the apparent conversion wait.

Keep both full scans; configure their decoder with `-threads 4`. Do not substitute
metadata-only probes, sample only part of the video, remove the source receipt,
or weaken the planner's source/final comparison. The encoder and its arguments
are unchanged: no lower resolution, lower quality, faster lossy preset or changed
audio bitrate was introduced by this optimization.

`-threads 4` is a decoder setting, not a process-wide or application-wide thread
ceiling. Concurrent jobs still share CPU and memory. This measurement is for one
local file; sustained ten-job performance and other Mac models remain unmeasured.

## Stage Contract

- `MediaProcessingStage` is a separate runner event inside existing postprocessing.
  The scheduler's `DownloadPhase` and non-pausable `.merging` status stay unchanged.
- Before source frame scanning, policy/receipt checks and encoder capability checks:
  `verifying` (Traditional Chinese: `驗證中`).
- Before FFmpeg processing: `converting` (`轉檔中`) if video or audio requires
  encoding, otherwise `remuxing` (`封裝中`).
- Before the complete final scan and publication checks: `verifying` again.
- Stage changes clear prior progress, transfer bytes, speed and ETA. Verification
  is indeterminate, including if a late 100% progress event arrives. Completion
  remains gated on successful verification and atomic publication.
- Stage and measured processing progress are runtime-only. Restored jobs must
  obtain fresh events; no stale conversion/verification state is deserialized.
- Existing cancellation, quit recovery, reservation ownership, Free policy,
  subtitle/artwork and source-preservation behavior remains in force.

The generic localized `Finishing` state remains the fallback for earlier yt-dlp
merge events and non-MP4 postprocessing without measured stage events. This change
does not claim a detailed progress percentage for full validation.

## Additional Integrity Guard

Some ffprobe decoders report errors on stderr but exit successfully. Since the
probe is invoked with `-v error`, any nonempty stderr now rejects the probe before
publication, including exit code zero. A failed probe retains the existing safe
error/source recovery path; it is not treated as a successful output.

## Measured Evidence

Local comparison file from the supplied `gsT6eKsnT0M` video: MP4 containing VP9
3840 x 2160 and Opus stereo, duration 333.114 seconds, 291952642 bytes. No download
or encoder operation occurred in this benchmark.

| Full scan | Wall seconds | User CPU seconds | System CPU seconds |
| --- | ---: | ---: | ---: |
| Previous default decoder threading | 69.47 | 69.03 | 0.33 |
| Four decoder threads | 23.27 | 71.73 | 0.79 |

Both scans returned exactly equal stream JSON, including 9983 video frames and
16656 audio frames. The observed wall-time reduction is about 66.5%, or 2.99x
throughput for this scan. CPU work is similar; it is parallelized, not omitted.
This is a single-file observation, not a guaranteed end-to-end speed multiplier.

A separate scan of the already converted 3840 x 2160 HEVC/AAC output measured
78.50 seconds with default threading and 26.33 seconds with four decoder threads.
The complete stream JSON was again equal (9983 video frames, 15615 AAC frames).
The optimized output scan was run first, then the default scan; no encoder or
other probe was run concurrently with this comparison.

Reproduce with the same local file and bundled tools, sequentially without other
encoders/probes running:

```sh
/usr/bin/time -p tools/ffprobe -v error -count_frames \
  -show_streams -show_format -of json "$INPUT" > default.json
/usr/bin/time -p tools/ffprobe -v error -threads 4 -count_frames \
  -show_streams -show_format -of json "$INPUT" > four-threads.json
jq -s '.[0].streams == .[1].streams' default.json four-threads.json
```

## Verification

- RED: default-thread command expectations failed, and error-level stderr with
  exit code zero incorrectly published the output. A missing final frame was
  already correctly rejected and remains covered.
- Stage-contract RED: new event/runtime properties were absent. GREEN: actual
  conversion/remux stage order, three-language labels, indeterminate validation,
  stale-metric clearing and runtime-only serialization tests passed.
- Public-flavor strict suite: 652 tests, 3 opt-in skips, zero failures.
- Bundled real-media suite: 14 tests, zero failures. Real 4K HEVC/Apple playback,
  subtitles, artwork, VFR, rotation and HDR safeguards retain coverage.
- Independent diff review: no actionable findings. Decoder threading is not a
  global resource limit; concurrency benchmarking remains a separate follow-up.
- Compiler warnings are errors; `git diff --check` passed.

Reproduction commands are the same strict and opt-in commands in
`4K_QUICKTIME_ACCEPTANCE.md`.

## Internal Candidate

- Source commit: `dfa6706`, clean tree at build time.
- Version/channel/architecture: 2.0.1 / internal-test / arm64, ad-hoc signed,
  not notarized and not for public distribution.
- Internal-flavor strict build suite: 658 tests, 3 opt-in skips, zero failures.
- Build exited zero; bundle verification reports `ok: true`, with no errors.
- App: `dist/swift-2.0/internal-test/YT Downloader Pro 2.app`.
- ZIP: `dist/swift-2.0/internal-test/YT-Downloader-Pro-2.0.1-macOS-arm64-internal-test.zip`.
- ZIP SHA-256: `a934f9b2552b250a1802b21013fea1dcc866b90397609d68c15780b972cef4f9`.
- Native launch smoke test: main window and settings opened successfully; 32
  existing records were retained. Traditional Chinese, Test Pro, five concurrent
  downloads, QuickTime-compatible mode and the original output directory remained
  unchanged. No owner history/media was cleared or fresh network job added.
- Actual processing-stage order is verified through runner/store/presentation
  tests and real bundled-media integration, not claimed as a manually observed
  live network-download UI session. Owner acceptance of the stage labels remains
  the next manual check.

Suggested owner check: download a 4K source in QuickTime-compatible mode and
observe verification, conversion and final verification. The verification label
must not retain the prior conversion's 100%. Open the completed output in
QuickTime, then repeat in original-encoding mode to check remuxing behavior.
