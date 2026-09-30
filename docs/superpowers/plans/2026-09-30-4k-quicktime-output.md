# 4K And QuickTime Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Restore all available resolutions without sacrificing QuickTime output compatibility or Free/Pro enforcement.

**Architecture:** Separate source selection from output compatibility. Metadata analysis chooses one complete client response; the download runner owns source download, stream probing, optional conversion, verification and atomic publication. Use the existing process, reservation, settings and policy boundaries.

**Tech Stack:** Swift, SwiftUI, XCTest, bundled yt-dlp, FFmpeg/ffprobe and VideoToolbox.

**Spec:** `docs/superpowers/specs/2026-09-30-4k-quicktime-output-design.md`

Status: owner approved starting Task 1 on 2026-09-30. Preserve native execution;
this turn is limited to Task 1. Tasks 2-6 remain pending.

## Global Constraints

- macOS Swift only. No payment, deployment, release or Windows changes.
- Free <=720p; encoding mode never grants Pro. Keep existing entitlement checks.
- Never silently downscale, access cookies, merge format IDs across clients, or overwrite media.
- MP4 defaults to quickTimeCompatible; originalEncoding is explicit. MP3 ignores this setting.
- No-cookie video analysis: at most two candidates. Cookie analysis: one opt-in attempt.
- Keep source dimensions, frame timing, rotation and supported color information; reject unsupported HDR conversion explicitly.
- No completed event before final output verification; conversion occupies the same scheduler slot.
- Each task: record RED, GREEN, refactor and focused verification; only commit coherent passing changes. Do not publish intermediate builds.

## Review Focus

1. Portrait/rotated video must retain display dimensions and orientation (Tasks 4, 5).
2. Cancellation between subprocesses must not start another process or complete a stale job (Tasks 2, 5).
3. Unknown persisted enum values must not become original mode or bypass Free limits (Tasks 1, 3).
4. SDR/HDR, 8/10-bit and attached artwork must not be mistaken for equivalent video streams (Task 4).
5. Full disks, destination races and repeat retries must preserve existing files and avoid duplicate output (Task 5).

## Paths And Verification

All paths below are relative to `.worktrees/main-release`. `S` means
`swift-2.0/Sources/YTDownloaderPro2`; `T` means
`swift-2.0/Tests/YTDownloaderPro2Tests`. Expand these prefixes when editing/staging.
Do not modify the older root checkout.

Run focused tests from the worktree with:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" swift test --package-path swift-2.0 --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter TEST_CLASS
```

Run the same command without `--filter TEST_CLASS` for full validation. Record
actual test counts and failures, not estimated counts. Use existing build script
flags discovered through its help for the internal-test packaging step.

### Task 1: Persist Output Mode And Show All Source Formats

**Files:** Modify `S/Models/DownloadOptions.swift`, `S/Models/MediaAnalysis.swift`,
`S/Views/MediaOptionsSheet.swift`, `S/Views/SettingsView.swift`,
`S/Resources/Localizable.xcstrings`; tests `T/ModelsTests.swift`,
`T/AppSettingsTests.swift`, `T/OptionsPresentationTests.swift`, `T/LocalizationTests.swift`.

**Interfaces:** Add `MP4OutputMode: String, Codable, Sendable` with
`quickTimeCompatible`, `originalEncoding`; add
`DownloadOptions.mp4OutputMode: MP4OutputMode`. Absent persisted field defaults
to compatible; unknown raw values throw decoding errors. Existing settings and
job persistence carry DownloadOptions; do not introduce another settings store.

- [x] RED: assert old options decode as compatible, round-trip both modes, and unknown values throw. Assert 2160p VP9/AV1 appear, Free locks them, Test Pro can select them, and MP3 behavior remains unchanged.
- [x] Run ModelsTests, AppSettingsTests and OptionsPresentationTests; capture the intended failures before implementation.
- [x] GREEN: implement the property/default decode and remove H.264/AAC-only presentation filtering. Keep existing FeaturePolicy menu logic and selected-ID identity.
- [x] Add a two-option picker to defaults and per-job options, with localized compatibility/conversion notices. Editing a queued job must not alter defaults. Do not claim re-encoding is lossless.
- [x] Verify all four test classes; refactor only duplicated presentation logic. This task is not an independently distributable build because the runner is not yet upgraded.
- [x] Commit only these files: `feat(swift): expose MP4 output mode and full resolution choices`.

### Task 2: Choose A Complete Analysis And Persist Its Client

**Files:** Modify `S/Models/MediaAnalysis.swift`, `S/Models/DownloadOptions.swift`,
`S/Services/MetadataProbe.swift`, `S/Services/YouTubeStrategy.swift`,
`S/Views/MediaOptionsSheet.swift`; tests `T/MetadataProbeTests.swift`,
`T/ModelsTests.swift`, `T/OptionsPresentationTests.swift`.

**Interfaces:** Add `YouTubeClientStrategy: String, Codable, Sendable` with
`webEmbedded`, `defaultClient`; optional `VideoAnalysis.clientStrategy` and
`DownloadOptions.clientStrategy`, default nil for legacy records. The selection
flow copies the winning analysis strategy to options. Unknown values throw.
Extend strategy argument construction to consume this bounded enum, never arbitrary client text.

- [ ] RED: embedded 360p success followed by default 2160p success chooses the entire second result, including its audio/subtitles/strategy. Equal maximum height chooses the result with more usable formats; exact ties choose first.
- [ ] RED: second error retains first usable result; cancellation stops immediately; two failures throw; cookie-enabled requests make one attempt; playlist expansion is unchanged; legacy records decode nil.
- [ ] Run MetadataProbeTests and ModelsTests and record expected failures.
- [ ] GREEN: compare at most two successful video candidates lexicographically by maximum height and usable format count. Exclude unusable entries using the existing decoder. Keep results separate. Preserve cancellation and existing error classification.
- [ ] Verify metadata, model and options tests; refactor candidate comparison into one pure helper used only by this probe.
- [ ] Commit: `fix(swift): retain the most complete bounded YouTube analysis`.

### Task 3: Select Sources Without A Codec Resolution Ceiling

**Files:** Modify `S/Services/YouTubeStrategy.swift`, `S/Models/DownloadOptions.swift`,
`S/Services/DownloadRunner.swift`; tests `T/YouTubeStrategyTests.swift`,
`T/FeaturePolicyTests.swift`, `T/DownloadRunnerTests.swift`.

**Interfaces:** Preserve existing strategy public entry points; source selectors
consume options from Tasks 1/2. Explicit IDs remain exact, while best selection
is codec-neutral. Runner policy normalization remains mandatory before launching.

- [ ] RED: Test Pro best can select VP9/AV1 2160p rather than avc1-only; explicit IDs are preserved in both modes; chosen client is used for download. Cookie choices remain opt-in.
- [ ] RED: Free best is height-capped at execution; forged/resumed high-resolution options are rejected or normalized under existing policy; unavailable explicit IDs on retry yield a selection error rather than lower-resolution fallback.
- [ ] Run YouTubeStrategyTests, FeaturePolicyTests and the focused runner regressions; record failures.
- [ ] GREEN: remove target-compatibility constraints from source selectors, retaining video+audio and progressive fallbacks. Keep client changes explicit on reanalysis and revalidate selections. Preserve subtitle SRT conversion and metadata arguments.
- [ ] Rerun all three classes and refactor duplicated selector construction without weakening URL validation.
- [ ] Commit: `fix(swift): decouple source resolution from MP4 compatibility`.

### Task 4: Probe Streams And Plan Verified Conversion

**Files:** Create `S/Services/MP4OutputPlanner.swift`, `T/MP4OutputPlannerTests.swift`;
modify `S/Models/MediaAnalysis.swift` only to consolidate obsolete compatibility helpers.

**Interfaces:** In the new file define `ProbedMedia: Decodable, Sendable` from
ffprobe JSON, with primary video/audio streams, subtitle/attachment streams,
duration, dimensions, pixel format, codec tag, rotation and color/HDR metadata.
Define `MP4EncoderCapabilities: Sendable`, `MP4OutputPlan: Sendable`, and
`MP4OutputPlanner.plan(media: ProbedMedia, mode: MP4OutputMode, capabilities: MP4EncoderCapabilities) throws -> MP4OutputPlan`.
Plan records independent video/audio copy or encode actions and validation expectations.
Add `MP4OutputPlanner.validate(output: ProbedMedia, source: ProbedMedia, mode: MP4OutputMode) throws`.

- [ ] RED: H.264 yuv420p + AAC copy; supported HEVC yuv420p/yuv420p10le with hvc1 copy; VP9/AV1 SDR encode video; Opus encodes audio; compatible video with Opus copies only video. Cover art is not primary video.
- [ ] RED: original mode never encodes; incompatible muxing fails clearly; malformed/empty probe, missing expected audio, changed dimensions, unsupported HDR conversion and unknown color handling fail closed. Include rotated portrait and variable-frame-rate fixtures.
- [ ] Run MP4OutputPlannerTests and record failures.
- [ ] GREEN: implement the pure decoder/planner. Prefer capability-tested hevc_videotoolbox, otherwise tested libx265. No available encoder is an actionable error. Preserve native timing; do not add a scaling filter or fixed frame-rate conversion. Use hvc1 for HEVC output.
- [ ] Verify actual bundled FFmpeg options before selecting encoder arguments. Start fixture evaluation with VideoToolbox quality mode and libx265 CRF 20/medium, AAC 192k when conversion is necessary; do not ship these until fixture visual checks pass. Capability detection must include successful synthetic encode, not just encoder listing.
- [ ] Generate short local synthetic 3840x2160 SDR fixtures, probe converted output and verify dimensions, frame timing, audio and QuickTime playback. Test HDR copy separately; reject HDR requiring conversion until preservation is verified. Document exact accepted encoder arguments and host/tool versions with evidence.
- [ ] Rerun planner tests; commit `feat(swift): plan and validate QuickTime-compatible MP4 output`.

### Task 5: Integrate Conversion With Owned Runner Lifecycle

**Files:** Modify `S/Services/DownloadRunner.swift`, `S/Services/ProgressParser.swift`,
`S/Services/YouTubeStrategy.swift`; tests `T/DownloadRunnerTests.swift`,
`T/ProgressParserTests.swift`, `T/OutputNameAllocatorTests.swift`,
`T/PersistenceControllerTests.swift`, `T/DownloadCoordinatorTests.swift`.

**Interfaces:** Consume Task 4 planner and existing
`ProcessLaunching.start(executable:arguments:) async throws -> RunningProcess`.
Runner tracks download/probe/encode/final-probe phases under the same job token.
Add `FFmpegProgressParser` producing elapsed-media-time values from `-progress pipe:1`;
use existing postprocessing progress events rather than a second scheduler job.

- [ ] RED: yt-dlp exit 0 alone cannot complete; ordered fake processes must run probe, optional encode, final probe, then publish. Any failed/missing/invalid output fails the job.
- [ ] RED: cancellation at every phase boundary terminates only the owned process, waits for exit, starts nothing else, never emits completed and removes only owned intermediates. Pause is unavailable during conversion.
- [ ] RED: disk-full and filename collision preserve existing media; stale callbacks cannot publish; retries after quit/crash restart encoding from verified retained source, not append. Sidecar SRT, embedded subtitles, artwork and metadata survive; cleanup never removes unrelated files.
- [ ] Run focused runner/progress/storage tests and record intended failures.
- [ ] GREEN: download to a unique job-owned source path on the destination filesystem, retaining reservation/security scope. Probe actual streams, execute the planner, then final-probe and atomically publish without replacement. Every await checks token/control state before starting another process.
- [ ] Preserve subtitle/attachment mappings explicitly rather than indiscriminate stream mapping. Keep owned recovery paths derivable from job identity; validate containment and source before reuse. Report probe/encoder/filesystem failures through localized app errors.
- [ ] Implement measured progress; zero/unknown durations show indeterminate progress. Await process exit before releasing scope/reservation or deleting temporary files.
- [ ] Rerun all five classes, refactor phase transitions, commit `fix(swift): verify converted media before completing downloads`.

### Task 6: Regression, Internal Packaging And Real Playback

**Files:** Add `docs/swift-2.0/4K_QUICKTIME_ACCEPTANCE.md`; update this plan's checkboxes only as evidence is obtained. No public manifest/version changes.

**Interfaces:** No new runtime interfaces. Exercise the integrated pipeline from Tasks 1-5.

- [ ] Run the full strict suite; fix regressions through RED/GREEN tests. Run `git diff --check` and review all changed files for policy bypass, file ownership and secret leakage.
- [ ] Build only the internal test flavor using existing `scripts/build_swift_2.sh` options. Record commit/dirty state, artifact path and SHA-256. Never reuse a stale artifact as proof.
- [ ] Verify Chinese/Japanese/English sheets/settings, old-job migration, Free locks, Test Pro 2160p, both output modes, default and queued-job persistence, batch policy, cancellation and retry.
- [ ] Freshly analyze gsT6eKsnT0M without cookies. Download a selected 4K result in compatible mode, confirm stream details with bundled ffprobe, then open in QuickTime and verify play, seek and audio. Repeat original mode and disclose its playback limitations. Network restrictions are blockers, not passing tests.
- [ ] Check synthetic portrait/VFR/HDR rejection, subtitles, duplicate filenames and source cleanup against the Task 4/5 fixtures. Record time/size and visual quality observations for chosen encoder settings.
- [ ] Review the complete diff and record unresolved risks. Commit evidence as `test(swift): record 4K QuickTime regression acceptance` only after actual checks. Offer internal artifact for owner testing; no release/push/merge without approval.

## Self-Review

Spec coverage: options/presentation (1), bounded complete analysis and client
persistence (2), source/policy/retry (3), codecs/color/encoder capability (4),
owned processes/files/recovery/subtitles (5), integration and playback (6).
Each review-focus case maps to a regression above. Task 4 types are the only new
conversion contract; Task 5 reuses the existing launcher. Final encoder quality
acceptance requires measured fixture evidence and must not be inferred from unit tests.

## Task 1 Execution Evidence (2026-09-30)

- RED: strict ModelsTests/OptionsPresentationTests run executed 57 tests with
  7 expected assertions failing: missing mode persistence/unknown-value rejection,
  Pro choosing 720p instead of VP9 2160p, and H.264/AAC-only default selection.
- Second RED: notice tests failed to compile because mp4ModeNotice and its
  localization keys were not implemented yet.
- GREEN: focused ModelsTests, AppSettingsTests, OptionsPresentationTests and
  LocalizationTests filter executed 84 tests with zero failures.
- Full strict suite: 597 tests, zero failures, one opt-in Keychain integration
  test skipped. `git diff --check` passed. Source changes reviewed locally;
  complete-branch independent review remains after Task 6.
- Ruling: SettingsView and PlaylistSelectionSheet already share DownloadOptionsEditor;
  add the mode picker there without duplicating UI or editing their call sites.
- Ruling: remove unused quickTimeVideoChoices/quickTimeAudioChoices, but retain
  compatibility helpers used by the current runner and advisory conversion notice.
- Ruling: /tmp/ytdp-clang-cache was used for the module cache. SwiftPM reports
  sandbox-restricted global-cache warnings; these are not source compilation failures.
- No packaged artifact, runtime conversion claim, external account action or
  release is part of Task 1. Live QuickTime/UI acceptance remains Task 6.
