# MP4 Output Planning And Validation

Task 4/5 evidence, 2026-10-03 through 2026-10-04. Internal macOS implementation only; not release
acceptance. The download runner now consumes the planner as described below.

## Contracts

- `ProbedMedia` decodes actual ffprobe JSON, not yt-dlp labels. Probe with
  `-v error -count_frames -show_streams -show_format -of json FILE`.
  Counting frames is deliberate: some Matroska inputs have no declared count.
  The runner must own/cancel this subprocess and show indeterminate progress
  when duration is unavailable. Full frame counting has a cost for long media.
- `MP4OutputPlanner.plan` is pure. It returns separate video/audio actions,
  retained source expectations and explicit stream mappings. It performs no
  process, filesystem, account or entitlement operations.
- Compatible mode copies H.264/yuv420p or supported HEVC/hvc1/yuv420p(10le).
  AAC is copied independently. Known BT.709 8-bit SDR can be HEVC encoded;
  non-AAC audio becomes AAC 192k. Neither scaling nor fixed-rate conversion is
  inserted. Rotation remains metadata (`-noautorotate`).
- HDR needing video conversion, unknown conversion color handling, and untested
  10-bit SDR conversion fail closed. Supported HEVC HDR is copy-only. Dynamic
  Dolby Vision/unknown HDR side data is not claimed compatible.
- Original mode copies video/audio only. A conservative codec allowlist rejects
  unsupported muxing requests. Actual mux failure is still authoritative.
  Text subtitles may become mov_text; that is separate from video encoding.
- Multiple primary videos/audio tracks and generic attachment/data streams fail
  explicitly, rather than being silently dropped. Cover JPEG/PNG is mapped
  separately and never mistaken for the primary video. Sidecar SRT is runner
  responsibility; this planner neither deletes nor moves it.
- `validate` checks MP4 container, coded dimensions, rotation, aspect ratio,
  color/HDR metadata, available frame counts/duration, audio presence/codec/
  channels/sample rate, subtitle language/count and artwork codec/dimensions.
  Original mode cannot silently change video/audio codecs.
- VFR averages differ across containers: validation requires a valid output
  rate when the source reports one, but does not require equal reported averages.
  Exact VFR timestamps are tested separately with `-show_frames`; stream-level
  validation alone is not a proof of every individual timestamp.
- Planning errors are typed and mapped to localized actionable UI. Encoder or
  unsupported color/stream errors offer edit-and-retry; a failed conversion is
  never marked completed.

## Encoder Capability Gate

`MP4EncoderCapabilities` starts empty. `recordProbe` accepts an encoder only
after exit zero AND validation of actual HEVC/hvc1 output against its synthetic
source. An encoder listing cannot grant capability. The runner executes
that probe with the same bundled binary and arguments; do not persist
one machine's capability as a universal entitlement or bundled default.

Candidate arguments (not a claim of lossless encoding):

| Encoder | Arguments | Evidence |
| --- | --- | --- |
| VideoToolbox | `-c:v:0 hevc_videotoolbox -q:v:0 65 -allow_sw 0 -profile:v:0 main` | Successful 4K SDR fixture on this host |
| libx265 | `-c:v:0 libx265 -crf 20 -preset medium` | Pure planner covered; unavailable in current bundle, not runtime-approved |

Conversion also sets yuv420p, passthrough timing, source BT.709/range, hvc1,
faststart, explicit mappings, metadata/chapter copying and no-overwrite output.
Quality parameters remain provisional until Task 6 real-content visual QA.
No software fallback is promised for the current bundle. Without a successful
encoder probe, return `encoderUnavailable`; never fall back to 1080p.

## Reproducible Tests

Run from the main-release worktree:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/ytdp-clang-cache \
  swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

env YTDP_RUN_MP4_TOOL_INTEGRATION=1 CLANG_MODULE_CACHE_PATH=/tmp/ytdp-clang-cache \
  swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors \
  --filter MP4Output
```

The opt-in test requires system VideoToolbox access. Under the execution sandbox
it returned compression-session error -12908; the same host outside that sandbox
encoded successfully. Do not classify that sandbox failure as universal hardware
incompatibility. Test files/logs remain in a printed temporary directory for QA.

## Observed Tool Evidence

- Host: arm64 macOS 26.5.2 (25F84). Bundled FFmpeg/ffprobe report version 9.0.
- FFmpeg SHA-256: `6460942f5665043fb23aab1964940afd7e1a707751b38142066e97381b00982d`.
- ffprobe SHA-256: `791a41a9821e4a3804f70050f67c2f4449a091ebf0b06dea178c54fe6d32a8e8`.
- Encoder help verified VideoToolbox Main/Main10 and pixel formats. libx265
  help reports unrecognized codec; a zero help exit code is NOT availability.
- SDR fixture: generated 2-second 3840x2160 FFV1 plus 48-kHz sine audio.
  Set BT.709 on generated frames with `setparams`; encoder flags alone did not
  populate all source color metadata in this build. Conversion retains all four
  color fields, 3840x2160, 48 frames, 24 fps, two seconds, HEVC hvc1 and AAC.
- AVFoundation accepted the result and decoded a 3840x2160 frame at one second.
  QuickTime UI opened it, entered playing state with visible test-pattern frames,
  and allowed timeline seeking. Human listening/audio-quality acceptance is not
  claimed by these checks.
- Synthetic HEVC Main10 PQ/BT.2020 copy passed metadata/codec/dimension checks.
  This verifies copy behavior, not HDR mastering fidelity or tone mapping.
- Rotated HEVC copy retained the 90-degree display matrix and portrait dimensions.
- VFR fixture retained 38 frames with source-relative timestamps within 2 ms
  (Matroska millisecond time base). No duplicate or dropped frames in this fixture.
- Aligned 48-frame SDR SSIM: 0.997421. Alignment was only for measurement
  (`settb=AVTB,setpts=N/(24*TB)` on both inputs); production does not retime frames.
  This synthetic score does not prove quality parity across encoders or content.

## Runner Lifecycle (Task 5)

`DownloadRunner` keeps one active job token, process slot, output reservation and
security-scoped folder access throughout download, probe, encoder capability
test, conversion/remux and final probe. Each asynchronous pipeline boundary
rechecks cancellation and token identity. A cancellation waits for the owned
process to exit before cleanup. Pause remains unavailable during postprocessing.
Large-source SHA-256 work runs in a job-owned detached task, checks cancellation
between bounded reads, and is awaited before cleanup; it does not block the runner
actor from handling controls for other jobs.

MP4 downloads use `.ytdp-<job UUID>/source.mp4` within the selected destination
volume, not the user's final filename. The workspace has a matching owner file;
symlinked workspaces/media are rejected. A SHA-256 receipt binds verified source
bytes to the URL and requested options (excluding a fallback client's identity).
Quit retains this source and reservation, discards incomplete conversion output,
and retry probes the source again before starting a fresh conversion. It never
appends to an interrupted conversion. Failed downloads without a matching receipt
must run yt-dlp again. The existing job ID/reserved basename persistence is reused;
no new persistence schema or second coordinator job is introduced.
A separate request digest preserves partial downloads only for unchanged options.
Changing options invalidates old source-dependent files, including subtitle
sidecars, before redownload. Quitting during publication recovery preserves the
candidate inode already linked to a public file, so another retry remains
idempotent rather than treating that file as an unrelated name collision.

Both source and final measured height are checked against current feature policy.
The source selection cap is not sufficient proof of Free compliance, and a plan
change during processing must not grant permission to publish restricted output.

`MP4Workspace.publish` uses no-replace hard links on the same volume. It publishes
SRT sidecars with the reserved basename and publishes the main MP4 last. A conflict
rolls back only links created by that call, never replaces existing media, and
leaves the source available for recovery. Inode identity allows recovery after a
publication-time crash. Filesystems without hard-link support fail closed rather
than using a potentially overwriting copy; external-volume compatibility needs
explicit acceptance testing before release. Cancel removes the owned private
workspace; downloaded media outside it is not a cleanup target.

FFmpeg progress uses actual `out_time_us` (or its legacy microsecond-valued
`out_time_ms` alias). Unknown/zero duration remains indeterminate. Conversion
progress never reaches 100% before final validation and publication. All generated
source/probe/candidate files count toward required free space; no silent resolution
downgrade or successful completion is substituted when space/encoding fails.

### Runner Integration Evidence

The opt-in `DownloadRunnerTests.testRealBundledRunnerConverts4KAndPreservesSubtitlesAndMetadata`
runs a fake downloader only for delivery of locally generated source bytes; probe,
capability encode, conversion and final validation use the actual bundled tools.
The 3840x2160 MPEG-4/AAC fixture exercises required video conversion, embedded
Japanese mov_text, sidecar SRT, an attached 64x64 PNG and title metadata. The output retained these,
used HEVC/hvc1 and AAC, and AVFoundation decoded a 2160p frame at 0.25 seconds.
This is not a real YouTube download or subjective quality acceptance.

Initial real-run RED exposed missing color-transfer/primaries in the synthetic
capability probe despite encoder flags. Adding `setparams` to the synthetic input
made the same integrated test pass without relaxing output validation.

## Remaining Gates

Task 6: supplied-video 4K testing, real-content quality comparison, playback/audio
and clean-Mac acceptance, then internal packaging. No public release is authorized
by this document or by a passing synthetic test.
