# MP4 Output Planning And Validation

Task 4 evidence, 2026-10-03. Internal macOS implementation only; not release
acceptance. The download runner does not consume this planner until Task 5.

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
- Planning errors are typed. Task 5 must map them to localized actionable UI,
  retain the owned source, and never mark a failed conversion completed.

## Encoder Capability Gate

`MP4EncoderCapabilities` starts empty. `recordProbe` accepts an encoder only
after exit zero AND validation of actual HEVC/hvc1 output against its synthetic
source. An encoder listing cannot grant capability. The future runner must
execute that probe with the same bundled binary and arguments; do not persist
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

## Remaining Gates

Task 5: connect probe/capability/encode/validation to owned process cancellation,
localized errors, file safety, metadata/sidecars and atomic publication.
Task 6: supplied-video 4K testing, real-content quality comparison, playback/audio
and clean-Mac acceptance, then internal packaging. No public release is authorized
by this document or by a passing synthetic test.
