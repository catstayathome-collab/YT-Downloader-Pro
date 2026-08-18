# YT Downloader Pro Swift 2.0 Download Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS 13+ SwiftUI download center with persistent multi-job cards, bundled media helpers, safe pause/resume, localized diagnostics, and platform-specific updates.

**Architecture:** A SwiftUI presentation store delegates all scheduling to actor-isolated services. Bundled `yt-dlp_macos`, FFmpeg, FFprobe, and QuickJS processes emit structured async events; jobs, thumbnail references, diagnostics, and settings persist outside the app bundle. The existing `develop/v2.0-swift` branch is reference-only, and implementation begins from the approved design branch based on current `main`.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, Foundation `Process`, actors and `AsyncStream`, Codable JSON persistence, String Catalogs, shell/Python packaging verification, GitHub Contents API.

**Spec:** `docs/superpowers/specs/2026-08-18-swift-2-download-center-design.md`

## Global Constraints

- Minimum deployment target is macOS 13 Ventura.
- Ship one universal app supporting Intel and Apple Silicon.
- Concurrency is user-configurable from 1 through 10 and defaults to 5.
- Defaults select the highest available video quality and highest available audio quality.
- Helpers live only in `Contents/Helpers/`; do not search Homebrew or PATH.
- Never disable TLS certificate verification.
- Never persist or log cookies, authorization data, or PO Tokens.
- Completed media is never removed by clearing a history record.
- The macOS app reads only `updates/macos.json`; Windows remains on `updates/windows.json`.
- All feature work follows test-driven development and ends in a focused commit.

## Planned File Structure

```text
swift-2.0/
  Package.swift
  Sources/YTDownloaderPro2/
    App/YTDownloaderPro2App.swift
    Models/AppSettings.swift
    Models/DownloadError.swift
    Models/DownloadEvent.swift
    Models/DownloadJob.swift
    Models/DownloadOptions.swift
    Models/DownloadStatus.swift
    Models/MediaAnalysis.swift
    Process/ProcessLauncher.swift
    Process/SystemProcessLauncher.swift
    Services/DiagnosticsLogger.swift
    Services/DownloadCoordinator.swift
    Services/DownloadRunner.swift
    Services/MetadataProbe.swift
    Services/OutputNameAllocator.swift
    Services/PersistenceController.swift
    Services/ThumbnailCache.swift
    Services/Toolchain.swift
    Services/UpdateChecker.swift
    Services/YouTubeStrategy.swift
    Stores/DownloadStore.swift
    Views/DownloadCardView.swift
    Views/DownloadCenterView.swift
    Views/ErrorDetailsView.swift
    Views/MediaOptionsSheet.swift
    Views/PlaylistSelectionSheet.swift
    Views/SettingsView.swift
    Resources/Localizable.xcstrings
  Tests/YTDownloaderPro2Tests/
    DiagnosticsLoggerTests.swift
    DownloadCoordinatorTests.swift
    DownloadRunnerTests.swift
    DownloadStoreTests.swift
    MetadataProbeTests.swift
    ModelsTests.swift
    OutputNameAllocatorTests.swift
    PersistenceControllerTests.swift
    ProgressParserTests.swift
    ThumbnailCacheTests.swift
    ToolchainTests.swift
    UpdateCheckerTests.swift
    YouTubeStrategyTests.swift
    Fixtures/
    TestSupport/Fixtures.swift
scripts/
  build_swift_2.sh
  check_swift_bundle.py
  create_macos_manifest.py
docs/
  SWIFT_2_TEST_CHECKLIST.md
updates/
  macos.json
  windows.json
tests/
  test_swift_bundle.py
```

Responsibility boundaries:

- `Models/` contains Codable, Sendable domain values and no process or UI logic.
- `Process/` is the only layer that wraps Foundation `Process`.
- `Services/` contains one focused actor or value service per behavior.
- `DownloadStore` translates service events into observable UI state.
- `Views/` renders state and sends commands; it does not construct helper arguments.
- Packaging scripts never import application UI code.

---

### Task 1: Swift Package, Domain Models, And State Rules

**Files:**
- Create: `swift-2.0/Package.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadStatus.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadOptions.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadJob.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadError.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Models/MediaAnalysis.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Models/AppSettings.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/ModelsTests.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/Fixtures.swift`

**Interfaces:**
- Produces: `DownloadStatus`, `DownloadOptions`, `DownloadJob`, `DownloadFailure`, `VideoAnalysis`, `PlaylistAnalysis`, and `AppSettings` as `Codable & Sendable` values.
- Produces: `DownloadStatus.canPause`, `DownloadStatus.sidebarSection`, and `DownloadJob.transition(to:at:) throws`.
- Produces test-only `DownloadJob.fixture(...)`, `DownloadJob.fixtures(count:)`, `DownloadOptions.fixture(...)`, `temporaryDirectory()`, and async collection helpers used by later tasks.

- [ ] **Step 1: Write model tests that define defaults and legal transitions**

```swift
import XCTest
@testable import YTDownloaderPro2

final class ModelsTests: XCTestCase {
    func testDefaultsUseBestQualityAndFiveWorkers() {
        XCTAssertEqual(DownloadOptions.defaults.videoQuality, .best)
        XCTAssertEqual(DownloadOptions.defaults.audioQuality, .best)
        XCTAssertEqual(AppSettings.defaults.maximumConcurrentDownloads, 5)
    }

    func testConcurrencyClampsToSupportedRange() {
        XCTAssertEqual(AppSettings(maximumConcurrentDownloads: 0).maximumConcurrentDownloads, 1)
        XCTAssertEqual(AppSettings(maximumConcurrentDownloads: 99).maximumConcurrentDownloads, 10)
    }

    func testMergingCannotPause() {
        XCTAssertFalse(DownloadStatus.merging.canPause)
        XCTAssertThrowsError(try DownloadJob.fixture(status: .merging).transition(to: .paused))
    }

    func testSidebarMappingMatchesDesign() {
        XCTAssertEqual(DownloadStatus.queued.sidebarSection, .running)
        XCTAssertEqual(DownloadStatus.cancelled.sidebarSection, .stopped)
        XCTAssertEqual(DownloadStatus.failed.sidebarSection, .failed)
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails because models do not exist**

Run: `cd swift-2.0 && swift test --filter ModelsTests`

Expected: FAIL with missing module types or missing target.

- [ ] **Step 3: Add the package and minimal domain implementation**

Use Swift tools 5.9, `.macOS(.v13)`, one executable target with processed `Resources`, and one test target. Define exact status cases from the spec. Represent qualities as:

```swift
enum VideoQuality: Codable, Equatable, Sendable { case best, format(id: String, label: String) }
enum AudioQuality: Codable, Equatable, Sendable { case best, format(id: String, label: String) }
enum OutputKind: String, Codable, Sendable { case mp4, mp3 }
```

`DownloadJob.transition` must reject `.merging -> .paused`, terminal-state regression to an active state, and direct `.queued -> .completed`.

Put shared test factories in `Tests/YTDownloaderPro2Tests/TestSupport/Fixtures.swift` rather than the production module. Provide defaults for title, status, output kind, cookie mode, retry count, and output URL so every later test invocation in this plan compiles without redefining fixtures.

- [ ] **Step 4: Run model tests and the full empty suite**

Run: `cd swift-2.0 && swift test --filter ModelsTests`

Expected: PASS.

Run: `cd swift-2.0 && swift test`

Expected: PASS.

- [ ] **Step 5: Commit the model foundation**

```bash
git add swift-2.0
git commit -m "feat(swift): establish download domain models"
```

### Task 2: Atomic Job Persistence And Settings

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/PersistenceController.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/PersistenceControllerTests.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/AppSettings.swift`

**Interfaces:**
- Consumes: `[DownloadJob]` and `AppSettings` from Task 1.
- Produces: `actor PersistenceController` with `loadJobs() async throws -> [DownloadJob]`, `saveJobs(_:flush:) async throws`, and `recoverInterruptedJobs(_:) -> [DownloadJob]`.
- Produces: `AppSettingsStore.load()` and `AppSettingsStore.save(_:)` backed by injected `UserDefaults`.

- [ ] **Step 1: Write persistence recovery tests**

```swift
final class PersistenceControllerTests: XCTestCase {
    func testRoundTripPersistsJobs() async throws {
        let root = try temporaryDirectory()
        let sut = PersistenceController(root: root)
        let jobs = [DownloadJob.fixture(title: "Example")]
        try await sut.saveJobs(jobs, flush: true)
        let loaded = try await sut.loadJobs()
        XCTAssertEqual(loaded, jobs)
    }

    func testInterruptedActiveJobsRestoreAsPaused() async throws {
        let sut = PersistenceController(root: try temporaryDirectory())
        let jobs = [.fixture(status: .downloading), .fixture(status: .queued)]
        let restored = await sut.recoverInterruptedJobs(jobs)
        XCTAssertEqual(restored.map(\.status), [.paused, .queued])
    }

    func testCorruptPrimaryUsesPreviousSnapshot() async throws {
        let root = try temporaryDirectory()
        let sut = PersistenceController(root: root)
        try await sut.saveJobs([.fixture(title: "Saved")], flush: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("downloads.json"))
        let loaded = try await sut.loadJobs()
        XCTAssertEqual(loaded.first?.title, "Saved")
    }
}
```

- [ ] **Step 2: Run the test and verify the service is missing**

Run: `cd swift-2.0 && swift test --filter PersistenceControllerTests`

Expected: FAIL with `cannot find PersistenceController in scope`.

- [ ] **Step 3: Implement versioned Codable snapshots and atomic replacement**

Use a private envelope:

```swift
private struct JobsSnapshot: Codable {
    let schemaVersion: Int
    let jobs: [DownloadJob]
}
```

Write to `State/downloads.next`, copy the last valid primary to `State/downloads.previous`, then atomically replace `downloads.json`. Convert `.analyzing`, `.downloading`, and `.merging` to `.paused` on startup. Keep queued and terminal statuses unchanged. Clamp settings on both decode and save. Store a user-selected output folder as a security-scoped bookmark and expose a resolved display URL; stale bookmarks must prompt for folder selection again instead of silently falling back.

- [ ] **Step 4: Run persistence and model tests**

Run: `cd swift-2.0 && swift test --filter PersistenceControllerTests`

Expected: PASS.

Run: `cd swift-2.0 && swift test --filter ModelsTests`

Expected: PASS.

- [ ] **Step 5: Commit persistence**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Services/PersistenceController.swift swift-2.0/Sources/YTDownloaderPro2/Models/AppSettings.swift swift-2.0/Tests/YTDownloaderPro2Tests/PersistenceControllerTests.swift
git commit -m "feat(swift): persist and recover download jobs"
```

### Task 3: Process Abstraction And Bundled Toolchain Validation

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Process/ProcessLauncher.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Process/SystemProcessLauncher.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/Toolchain.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/ToolchainTests.swift`

**Interfaces:**
- Produces: `ProcessResult(exitCode: Int32, stdout: String, stderr: String)`.
- Produces: `protocol ProcessRunning { func run(executable: URL, arguments: [String]) async throws -> ProcessResult }`.
- Produces: `Toolchain.resolve(bundle:) throws -> Toolchain` and `ToolchainValidator.validate(_:) async throws -> ToolchainHealth`.

- [ ] **Step 1: Write tests for canonical helper paths and real health commands**

```swift
final class ToolchainTests: XCTestCase {
    func testResolveUsesOnlyContentsHelpers() throws {
        let bundle = try fakeBundle(helperNames: ["yt-dlp_macos", "ffmpeg", "ffprobe", "qjs"])
        let tools = try Toolchain.resolve(bundle: bundle)
        XCTAssertTrue(tools.ffmpeg.path.contains("Contents/Helpers/ffmpeg"))
    }

    func testValidatorRunsEveryVersionCommand() async throws {
        let runner = RecordingProcessRunner(successfulToolOutputs: true)
        _ = try await ToolchainValidator(processRunner: runner).validate(.fixture())
        XCTAssertEqual(runner.commands.map(\.arguments), [["--version"], ["-version"], ["-version"], ["--help"]])
    }

    func testMissingOrNonExecutableHelperIsLocalizedToolFailure() async {
        let runner = RecordingProcessRunner(failingTool: "ffmpeg")
        do {
            _ = try await ToolchainValidator(processRunner: runner).validate(.fixture())
            XCTFail("Expected helper validation failure")
        } catch {
            XCTAssertEqual((error as? DownloadFailure)?.category, .bundledConverterUnavailable)
        }
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd swift-2.0 && swift test --filter ToolchainTests`

Expected: FAIL because process and toolchain types do not exist.

- [ ] **Step 3: Implement process execution and validation**

Use continuations to run `Process` off the main actor and read both pipes without deadlock. Require canonical filenames, executable permission, exit codes accepted by each version command, matching FFmpeg/FFprobe versions, and QuickJS output containing `QuickJS version`. Return stable error categories without exposing raw stderr as the user alert.

- [ ] **Step 4: Run toolchain tests**

Run: `cd swift-2.0 && swift test --filter ToolchainTests`

Expected: PASS.

- [ ] **Step 5: Commit toolchain validation**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Process swift-2.0/Sources/YTDownloaderPro2/Services/Toolchain.swift swift-2.0/Tests/YTDownloaderPro2Tests/ToolchainTests.swift
git commit -m "feat(swift): validate bundled helper toolchain"
```

### Task 4: YouTube Strategy And Metadata Analysis

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/YouTubeStrategy.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/MetadataProbe.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/YouTubeStrategyTests.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/MetadataProbeTests.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/video-analysis.json`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/playlist-analysis.json`

**Interfaces:**
- Consumes: `Toolchain`, `DownloadOptions`, and `ProcessRunning`.
- Produces: `YouTubeStrategy.analysisArguments(url:options:attempt:) -> [String]` and `downloadArguments(job:toolchain:attempt:) -> [String]`.
- Produces: `MetadataProbe.analyze(url:options:) async throws -> AnalysisResult`, where `AnalysisResult` is `.video(VideoAnalysis)` or `.playlist(PlaylistAnalysis)`.

- [ ] **Step 1: Write argument safety and fixture parsing tests**

```swift
final class YouTubeStrategyTests: XCTestCase {
    func testAnalysisUsesQuickJSAndVerifiedClientWithoutDisablingTLS() {
        let args = YouTubeStrategy(toolchain: .fixture()).analysisArguments(
            url: "https://youtu.be/example", options: .defaults, attempt: 0
        )
        XCTAssertTrue(args.contains("quickjs:" + Toolchain.fixture().qjs.path))
        XCTAssertTrue(args.contains("youtube:player_client=web_embedded"))
        XCTAssertFalse(args.contains("--no-check-certificate"))
    }

    func testCookiesAreAddedOnlyWhenExplicitlySelected() {
        let none = YouTubeStrategy(toolchain: .fixture()).analysisArguments(url: "u", options: .defaults, attempt: 0)
        let chrome = YouTubeStrategy(toolchain: .fixture()).analysisArguments(url: "u", options: .fixture(cookies: .chrome), attempt: 0)
        XCTAssertFalse(none.contains("--cookies-from-browser"))
        XCTAssertTrue(chrome.contains("--cookies-from-browser"))
    }
}
```

Add metadata tests that assert the video fixture sorts highest resolution and highest bitrate first, and the playlist fixture preserves source order and entry IDs.

- [ ] **Step 2: Run both focused suites and verify failure**

Run: `cd swift-2.0 && swift test --filter YouTubeStrategyTests`

Expected: FAIL because `YouTubeStrategy` does not exist.

Run: `cd swift-2.0 && swift test --filter MetadataProbeTests`

Expected: FAIL because `MetadataProbe` does not exist.

- [ ] **Step 3: Implement centralized arguments and typed JSON decoding**

Use `--dump-single-json`, `--skip-download`, `--no-warnings`, `--js-runtimes quickjs:<path>`, and reviewed extractor arguments matching the latest stable Python strategy. Decode typed nested structs instead of `[String: Any]`. Deduplicate formats by format ID, preserve codec, container, resolution, FPS, bitrate, language, and filesize estimates, and make best quality the first choice.

Define a bounded fallback list in `YouTubeStrategy`; attempt zero uses the current verified client and later entries are only used for retryable 403/client failures. Do not add PO Token acquisition.

- [ ] **Step 4: Run metadata and strategy tests**

Run: `cd swift-2.0 && swift test --filter YouTubeStrategyTests`

Expected: PASS.

Run: `cd swift-2.0 && swift test --filter MetadataProbeTests`

Expected: PASS.

- [ ] **Step 5: Commit analysis support**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Services/YouTubeStrategy.swift swift-2.0/Sources/YTDownloaderPro2/Services/MetadataProbe.swift swift-2.0/Tests/YTDownloaderPro2Tests
git commit -m "feat(swift): analyze videos and playlists safely"
```

### Task 5: Streaming Process Events And Progress Parsing

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Process/ProcessLauncher.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Process/SystemProcessLauncher.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadEvent.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/ProgressParser.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/ProgressParserTests.swift`

**Interfaces:**
- Produces: `ProcessEvent.stdoutLine(String)`, `.stderrLine(String)`, and `.terminated(Int32)`.
- Produces: `actor RunningProcess` with `events: AsyncStream<ProcessEvent>`, `interrupt()`, and `terminate()`.
- Produces: `JobProgress` and `DownloadEvent.phase`, `.progress`, `.output`, `.diagnostic`, `.completed`.
- Produces: `ProgressParser.parse(line:) -> [DownloadEvent]`.

- [ ] **Step 1: Write parser fixtures for download, merge, filepath, and error output**

```swift
final class ProgressParserTests: XCTestCase {
    func testParsesStructuredProgressTemplate() {
        let events = ProgressParser().parse(line: "ytdp:progress|67.5|245000000|366000000|12400000|12")
        XCTAssertEqual(events, [.progress(.init(fraction: 0.675, downloadedBytes: 245000000, totalBytes: 366000000, bytesPerSecond: 12400000, etaSeconds: 12))])
    }

    func testDetectsMergingAndFinalPath() {
        XCTAssertEqual(ProgressParser().parse(line: "ytdp:phase|merging"), [.phase(.merging)])
        XCTAssertEqual(ProgressParser().parse(line: "ytdp:filepath|/tmp/video.mp4"), [.output(URL(fileURLWithPath: "/tmp/video.mp4"))])
    }
}
```

- [ ] **Step 2: Run and confirm missing parser failure**

Run: `cd swift-2.0 && swift test --filter ProgressParserTests`

Expected: FAIL because `ProgressParser` and `DownloadEvent` do not exist.

- [ ] **Step 3: Implement line-buffered streaming and structured parser**

Make the process wrapper preserve partial UTF-8 lines across reads and close the stream once. Configure `yt-dlp` templates in `YouTubeStrategy` so parsing does not depend on localized human text. Permit human stderr only as diagnostic detail and detect known postprocessor lines as a fallback.

- [ ] **Step 4: Run parser and process-related tests**

Run: `cd swift-2.0 && swift test --filter ProgressParserTests`

Expected: PASS.

Run: `cd swift-2.0 && swift test --filter ToolchainTests`

Expected: PASS.

- [ ] **Step 5: Commit streaming process support**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Process swift-2.0/Sources/YTDownloaderPro2/Models/DownloadEvent.swift swift-2.0/Sources/YTDownloaderPro2/Services/ProgressParser.swift swift-2.0/Tests/YTDownloaderPro2Tests/ProgressParserTests.swift
git commit -m "feat(swift): stream structured download progress"
```

### Task 6: Concurrency-Safe Output Naming

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/OutputNameAllocator.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/OutputNameAllocatorTests.swift`

**Interfaces:**
- Produces: `actor OutputNameAllocator` with `reserve(title:extension:directory:jobID:) async throws -> OutputReservation` and `release(jobID:removeMarker:) async`.
- Produces: `OutputReservation(baseURL: URL, markerURL: URL)`.

- [ ] **Step 1: Write sanitization and concurrent collision tests**

```swift
final class OutputNameAllocatorTests: XCTestCase {
    func testExistingFileProducesNumberedName() async throws {
        let root = try temporaryDirectory()
        try Data().write(to: root.appendingPathComponent("Title.mp4"))
        let reservation = try await OutputNameAllocator().reserve(title: "Title", extension: "mp4", directory: root, jobID: UUID())
        XCTAssertEqual(reservation.baseURL.lastPathComponent, "Title (1)")
    }

    func testConcurrentReservationsNeverMatch() async throws {
        let root = try temporaryDirectory()
        let allocator = OutputNameAllocator()
        async let first = allocator.reserve(title: "Same", extension: "mp4", directory: root, jobID: UUID())
        async let second = allocator.reserve(title: "Same", extension: "mp4", directory: root, jobID: UUID())
        let (firstReservation, secondReservation) = try await (first, second)
        XCTAssertNotEqual(firstReservation.baseURL, secondReservation.baseURL)
    }

    func testSanitizationRemovesForbiddenCharacters() async throws {
        let result = try await OutputNameAllocator().reserve(title: "A/B:C?", extension: "mp4", directory: try temporaryDirectory(), jobID: UUID())
        XCTAssertEqual(result.baseURL.lastPathComponent, "ABC")
    }
}
```

- [ ] **Step 2: Run and verify allocator is missing**

Run: `cd swift-2.0 && swift test --filter OutputNameAllocatorTests`

Expected: FAIL.

- [ ] **Step 3: Implement actor reservations and marker ownership**

Check existing final extensions, persisted reservations, and in-memory reservations while inside the actor. Create a hidden marker containing only the job UUID. Never remove a path unless its marker UUID matches the job being released. Persist the chosen basename on `DownloadJob` before launching `yt-dlp`.

- [ ] **Step 4: Run allocator tests repeatedly**

Run: `cd swift-2.0 && swift test --filter OutputNameAllocatorTests`

Expected: PASS on three consecutive runs.

- [ ] **Step 5: Commit output reservation**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Services/OutputNameAllocator.swift swift-2.0/Tests/YTDownloaderPro2Tests/OutputNameAllocatorTests.swift
git commit -m "feat(swift): reserve unique output names"
```

### Task 7: Download Runner, Pause, Cancel, And Retry

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/DownloadRunner.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadRunnerTests.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/fake-yt-dlp.sh`

**Interfaces:**
- Consumes: `Toolchain`, `YouTubeStrategy`, `OutputNameAllocator`, `ProgressParser`, and `ProcessLaunching`.
- Produces: `actor DownloadRunner` with `events(for:) -> AsyncThrowingStream<DownloadEvent, Error>`, `pause(jobID:) async`, `cancel(jobID:) async`, and `interruptForQuit(jobID:) async`.
- Produces: `protocol JobRunning` with the same event and control methods; `DownloadRunner` conforms so Task 8 can inject a deterministic fake.

- [ ] **Step 1: Write fake-process lifecycle tests**

```swift
final class DownloadRunnerTests: XCTestCase {
    func testSuccessfulRunEmitsDownloadingMergingAndCompleted() async throws {
        let runner = DownloadRunner.fixture(script: .successfulDownload)
        let events = try await collect(runner.events(for: .fixture()))
        XCTAssertTrue(events.contains(.phase(.downloading)))
        XCTAssertTrue(events.contains(.phase(.merging)))
        XCTAssertTrue(events.contains(.completed))
    }

    func testPauseKeepsPartFileAndCancelRemovesOwnedArtifacts() async throws {
        let environment = try RunnerFixture.make()
        let job = DownloadJob.fixture()
        let task = Task { try await collect(environment.runner.events(for: job)) }
        await environment.waitUntilPartExists()
        await environment.runner.pause(jobID: job.id)
        XCTAssertTrue(environment.partFileExists)
        await environment.runner.cancel(jobID: job.id)
        XCTAssertFalse(environment.partFileExists)
        task.cancel()
    }

    func testRetryReanalyzesBeforeStartingDownload() async throws {
        let runner = DownloadRunner.fixture(script: .retryable403ThenSuccess)
        _ = try await collect(runner.events(for: .fixture(retryCount: 1)))
        let phases = await runner.recordedPhases
        XCTAssertEqual(Array(phases.prefix(2)), [.analyzing, .downloading])
    }
}
```

- [ ] **Step 2: Run runner tests and verify failure**

Run: `cd swift-2.0 && swift test --filter DownloadRunnerTests`

Expected: FAIL because the runner is missing.

- [ ] **Step 3: Implement one-process-per-job lifecycle**

Store active handles by job UUID. Pause sends an interrupt, escalates to termination after a bounded timeout, and retains `.part` files. Cancel terminates and deletes only tracked owned artifacts. Merging rejects user pause; quit interruption removes incomplete merge output but retains source streams. Retry invokes `MetadataProbe` first and requests format reselection when a saved format ID disappears.

- [ ] **Step 4: Run runner, parser, and naming tests**

Run: `cd swift-2.0 && swift test --filter DownloadRunnerTests`

Expected: PASS.

Run: `cd swift-2.0 && swift test --filter ProgressParserTests`

Expected: PASS.

Run: `cd swift-2.0 && swift test --filter OutputNameAllocatorTests`

Expected: PASS.

- [ ] **Step 5: Commit runner lifecycle**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Services/DownloadRunner.swift swift-2.0/Tests/YTDownloaderPro2Tests/DownloadRunnerTests.swift swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/fake-yt-dlp.sh
git commit -m "feat(swift): run and control individual downloads"
```

### Task 8: Dynamic Download Coordinator

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/DownloadCoordinator.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCoordinatorTests.swift`

**Interfaces:**
- Consumes: `any JobRunning` and job IDs supplied by the store.
- Produces: `CoordinatorEvent.started(UUID)`, `.runnerEvent(UUID, DownloadEvent)`, and `.stopped(UUID, DownloadStatus)`.
- Produces: `actor DownloadCoordinator` with `enqueue(_:)`, `setLimit(_:)`, `startNow(_:)`, `pause(_:)`, `resume(_:)`, `cancel(_:)`, and `shutdown()`.

- [ ] **Step 1: Write deterministic worker-pool tests using a gated fake runner**

```swift
final class DownloadCoordinatorTests: XCTestCase {
    func testDefaultLimitStartsFiveJobs() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 5, runner: runner)
        await coordinator.enqueue(DownloadJob.fixtures(count: 8))
        let startedCount = await runner.startedCount
        XCTAssertEqual(startedCount, 5)
    }

    func testLowerLimitDoesNotTerminateRunningJobs() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 5, runner: runner)
        await coordinator.enqueue(DownloadJob.fixtures(count: 8))
        await coordinator.setLimit(2)
        let activeCount = await runner.activeCount
        XCTAssertEqual(activeCount, 5)
        await runner.finishOne()
        let startedCount = await runner.startedCount
        XCTAssertEqual(startedCount, 5)
    }

    func testFailureStartsNextJobAndDoesNotStopOthers() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 2, runner: runner)
        await coordinator.enqueue(DownloadJob.fixtures(count: 3))
        await runner.failOne()
        let startedCount = await runner.startedCount
        XCTAssertEqual(startedCount, 3)
    }
}
```

- [ ] **Step 2: Run and verify coordinator is missing**

Run: `cd swift-2.0 && swift test --filter DownloadCoordinatorTests`

Expected: FAIL.

- [ ] **Step 3: Implement the actor worker pool**

Track queued order, active task IDs, the target limit, and per-job commands. `startNow` moves an eligible queued job to the front but never exceeds the limit. Decreasing the limit blocks replacement workers until active count drops below the new limit. `shutdown` pauses interruptible jobs, uses quit interruption for merging jobs, awaits termination, and emits final paused states.

- [ ] **Step 4: Run limits 1, 5, and 10 plus the full coordinator suite**

Run: `cd swift-2.0 && swift test --filter DownloadCoordinatorTests`

Expected: PASS including explicit tests for limits 1, 5, and 10.

- [ ] **Step 5: Commit coordinator**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Services/DownloadCoordinator.swift swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCoordinatorTests.swift
git commit -m "feat(swift): schedule concurrent download jobs"
```

### Task 9: Thumbnail Cache And Sanitized Diagnostics

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/ThumbnailCache.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/DiagnosticsLogger.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/ThumbnailCacheTests.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/DiagnosticsLoggerTests.swift`

**Interfaces:**
- Produces: `ThumbnailCache.store(data:for:)`, `url(for:)`, and `remove(jobID:)`.
- Produces: `DiagnosticsLogger.record(_:)`, `details(for:)`, and `rotateIfNeeded()`.

- [ ] **Step 1: Write cache deletion and secret-redaction tests**

```swift
final class DiagnosticsLoggerTests: XCTestCase {
    func testSecretsAreRedactedBeforeDiskWrite() async throws {
        let logger = DiagnosticsLogger(root: try temporaryDirectory())
        await logger.record(.fixture(arguments: ["--cookies", "secret.txt", "https://x.test?v=1&sig=secret"]))
        let logURL = await logger.currentLogURL
        let text = try String(contentsOf: logURL)
        XCTAssertFalse(text.contains("secret.txt"))
        XCTAssertFalse(text.contains("sig=secret"))
        XCTAssertTrue(text.contains("[REDACTED]"))
    }
}

final class ThumbnailCacheTests: XCTestCase {
    func testRemovingRecordDeletesOnlyItsCachedThumbnail() async throws {
        let cache = ThumbnailCache(root: try temporaryDirectory())
        let first = UUID(), second = UUID()
        try await cache.store(data: Data([1]), for: first)
        try await cache.store(data: Data([2]), for: second)
        try await cache.remove(jobID: first)
        let firstURL = await cache.url(for: first)
        let secondURL = await cache.url(for: second)
        XCTAssertNil(firstURL)
        XCTAssertNotNil(secondURL)
    }
}
```

- [ ] **Step 2: Run both suites and verify failure**

Run: `cd swift-2.0 && swift test --filter DiagnosticsLoggerTests`

Expected: FAIL.

Run: `cd swift-2.0 && swift test --filter ThumbnailCacheTests`

Expected: FAIL.

- [ ] **Step 3: Implement cache ownership, URLSession injection, JSONL, and rotation**

Name thumbnails by job UUID and validated image extension. Reject non-HTTP(S) remote thumbnail URLs. Serialize diagnostics as one Codable event per line, redact sensitive flags and URL query values before serialization, and rotate at 5 MB while retaining three files.

- [ ] **Step 4: Run both focused suites**

Run: `cd swift-2.0 && swift test --filter DiagnosticsLoggerTests`

Expected: PASS.

Run: `cd swift-2.0 && swift test --filter ThumbnailCacheTests`

Expected: PASS.

- [ ] **Step 5: Commit cache and diagnostics**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Services/ThumbnailCache.swift swift-2.0/Sources/YTDownloaderPro2/Services/DiagnosticsLogger.swift swift-2.0/Tests/YTDownloaderPro2Tests/ThumbnailCacheTests.swift swift-2.0/Tests/YTDownloaderPro2Tests/DiagnosticsLoggerTests.swift
git commit -m "feat(swift): cache thumbnails and sanitize diagnostics"
```

### Task 10: Observable Download Store And Relaunch Recovery

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift`

**Interfaces:**
- Consumes: coordinator events, persistence, thumbnails, diagnostics, settings, and metadata analysis.
- Produces: `@MainActor final class DownloadStore: ObservableObject` with published `jobs`, `selection`, `sidebarSection`, `analysisState`, and `settings`.
- Produces commands: `analyzeURL`, `addVideo`, `addPlaylistEntries`, `editQueuedJob`, `startAll`, `pauseAll`, `resumeAll`, `cancel`, `retry`, `removeRecord`, `clearCompleted`, and `prepareToQuit`.

- [ ] **Step 1: Write store behavior tests**

```swift
@MainActor
final class DownloadStoreTests: XCTestCase {
    func testPlaylistBatchCreatesOneQueuedJobPerSelectedEntry() async throws {
        let store = DownloadStore.fixture(analysis: .playlist(.fixture(entryCount: 3)))
        await store.analyzeURL("https://youtube.test/playlist")
        await store.addPlaylistEntries(selectedIDs: ["1", "3"], options: .defaults)
        XCTAssertEqual(store.jobs.map(\.status), [.queued, .queued])
    }

    func testOnlyQueuedJobCanBeEdited() async throws {
        let store = DownloadStore.fixture(jobs: [.fixture(status: .queued), .fixture(status: .paused)])
        let queuedWasEdited = await store.editQueuedJob(store.jobs[0].id, options: .fixture(output: .mp3))
        let pausedWasEdited = await store.editQueuedJob(store.jobs[1].id, options: .fixture(output: .mp3))
        XCTAssertTrue(queuedWasEdited)
        XCTAssertFalse(pausedWasEdited)
    }

    func testRemoveCompletedRecordKeepsMediaFile() async throws {
        let fixture = try StoreFixture.completedJobWithMedia()
        await fixture.store.removeRecord(fixture.job.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path))
    }
}
```

- [ ] **Step 2: Run and verify store is missing**

Run: `cd swift-2.0 && swift test --filter DownloadStoreTests`

Expected: FAIL.

- [ ] **Step 3: Implement store command routing and persistence cadence**

Translate coordinator events into legal job transitions on the main actor. Persist immediately for queue/status/output/error changes and debounce progress-only saves. Keep filtered views derived from the full retained job list. `prepareToQuit` awaits coordinator shutdown and a flushed persistence save before allowing termination.

- [ ] **Step 4: Run store and persistence suites**

Run: `cd swift-2.0 && swift test --filter DownloadStoreTests`

Expected: PASS.

Run: `cd swift-2.0 && swift test --filter PersistenceControllerTests`

Expected: PASS.

- [ ] **Step 5: Commit the application store**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift
git commit -m "feat(swift): connect persistent download state"
```

### Task 11: Approved Sidebar, URL Bar, And Download Cards

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCenterView.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCardView.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/ErrorDetailsView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift`

**Interfaces:**
- Consumes: `DownloadStore` only.
- Produces: the approved near-white main window, persistent status sidebar, URL field, Analyze action, bulk commands, and state-specific cards.

- [ ] **Step 1: Add view-state tests that do not depend on pixel snapshots**

Extract `DownloadCardPresentation` and test it:

```swift
final class DownloadCenterViewTests: XCTestCase {
    func testMergingCardDoesNotExposePause() {
        let presentation = DownloadCardPresentation(job: .fixture(status: .merging))
        XCTAssertFalse(presentation.actions.contains(.pause))
        XCTAssertTrue(presentation.actions.contains(.cancelWithConfirmation))
    }

    func testCompletedCardExposesPlayRevealAndRemove() {
        let actions = DownloadCardPresentation(job: .fixture(status: .completed)).actions
        XCTAssertEqual(actions, [.play, .revealInFinder, .removeRecord])
    }
}
```

- [ ] **Step 2: Run and verify presentation types are missing**

Run: `cd swift-2.0 && swift test --filter DownloadCenterViewTests`

Expected: FAIL.

- [ ] **Step 3: Implement the approved SwiftUI composition**

Use `NavigationSplitView` with a fixed-width sidebar and a flexible main list. Keep the URL field and Analyze button always visible. Use `LazyVStack` cards with fixed thumbnail aspect ratio, stable action button dimensions, `ProgressView`, and SF Symbols. Do not nest cards, use decorative gradients, or show feature-instruction text in the shipped interface. Provide tooltips and accessibility labels for every icon action.

Map card actions exactly: queued has Edit, Start Now, and Cancel; analyzing/downloading has Pause and Cancel; paused has Resume and Cancel; merging has confirmed Cancel only; completed has Play, Reveal in Finder, and Remove Record; failed has Retry, Error Details, and Remove Record; cancelled has Re-add and Remove Record. Add Start All, Pause All, Resume All, confirmed Cancel Active/Waiting, and Clear Completed above the card list.

- [ ] **Step 4: Run view-state tests and launch a debug app**

Run: `cd swift-2.0 && swift test --filter DownloadCenterViewTests`

Expected: PASS.

Run: `cd swift-2.0 && swift run YTDownloaderPro2`

Expected: the app opens with the sidebar, URL row, empty state, and Settings button without helper-dependent startup crash.

- [ ] **Step 5: Commit the main interface**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Views swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift
git commit -m "feat(swift): build card-based download center"
```

### Task 12: Media Options, Playlist Selection, And Keyboard Commands

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/MediaOptionsSheet.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/PlaylistSelectionSheet.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCenterView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/OptionsPresentationTests.swift`

**Interfaces:**
- Consumes: typed metadata and store commands.
- Produces: central single-video sheet, playlist selection sheet with shared defaults, queued-card editing, settings, and keyboard command routing.

- [ ] **Step 1: Write option and selection behavior tests**

```swift
final class OptionsPresentationTests: XCTestCase {
    func testVideoSheetDefaultsToHighestVideoAndAudio() {
        let model = MediaOptionsPresentation(analysis: .fixture(), defaults: .defaults)
        XCTAssertEqual(model.selectedVideoID, model.videoChoices.first?.id)
        XCTAssertEqual(model.selectedAudioID, model.audioChoices.first?.id)
    }

    func testPlaylistStartsFullySelectedAndSupportsCommandA() {
        var model = PlaylistSelectionPresentation(analysis: .fixture(entryCount: 4))
        XCTAssertEqual(model.selectedIDs.count, 4)
        model.clearSelection()
        model.selectAll()
        XCTAssertEqual(model.selectedIDs.count, 4)
    }
}
```

- [ ] **Step 2: Run and verify sheet models are missing**

Run: `cd swift-2.0 && swift test --filter OptionsPresentationTests`

Expected: FAIL.

- [ ] **Step 3: Implement sheets and commands**

Present `MediaOptionsSheet` after single-video analysis and `PlaylistSelectionSheet` after playlist analysis. Expose video quality, audio quality, MP4/MP3, subtitle mode and language, embedded thumbnail, embedded metadata, cookies mode, and output folder. Batch options apply to selected entries; only queued cards show Edit. Add Enter for analysis, Space for selected-job pause/resume, Delete for record removal confirmation, and Command-A only inside the playlist sheet. Preserve normal Command-V behavior and only route a supported clipboard URL when focus is outside editable text.

- [ ] **Step 4: Run option tests and manually verify keyboard focus**

Run: `cd swift-2.0 && swift test --filter OptionsPresentationTests`

Expected: PASS.

Run: `cd swift-2.0 && swift run YTDownloaderPro2`

Expected: Enter opens the correct central sheet; playlist selection defaults to all; keyboard actions never fire while typing in unrelated fields.

- [ ] **Step 5: Commit analysis sheets and shortcuts**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Views swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift swift-2.0/Tests/YTDownloaderPro2Tests/OptionsPresentationTests.swift
git commit -m "feat(swift): add format sheets and keyboard commands"
```

### Task 13: Localization And Actionable Errors

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadError.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/ErrorDetailsView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift`

**Interfaces:**
- Consumes: stable `DownloadFailure.Category` values.
- Produces: Traditional Chinese, English, and Japanese summary and recovery strings for every category plus all visible labels, commands, tooltips, and accessibility names.

- [ ] **Step 1: Write localization completeness and raw-error suppression tests**

```swift
final class LocalizationTests: XCTestCase {
    func testEveryFailureCategoryHasThreeLocalizedSummaries() throws {
        for locale in ["zh-Hant", "en", "ja"] {
            for category in DownloadFailure.Category.allCases {
                XCTAssertFalse(try catalogValue(key: category.summaryKey, locale: locale).isEmpty)
                XCTAssertFalse(try catalogValue(key: category.recoveryKey, locale: locale).isEmpty)
            }
        }
    }

    func testFFmpegFailureUsesProductMessageInsteadOfRawHelperText() {
        let failure = DownloadFailure.classify(stderr: "ffmpeg is not installed")
        XCTAssertEqual(failure.category, .bundledConverterUnavailable)
        XCTAssertFalse(failure.userSummary(locale: "zh-Hant").contains("ffmpeg is not installed"))
    }
}
```

- [ ] **Step 2: Run and verify missing catalog failure**

Run: `cd swift-2.0 && swift test --filter LocalizationTests`

Expected: FAIL.

- [ ] **Step 3: Add the string catalog and deterministic error classifier**

Cover invalid URL, unavailable/private/region-restricted video, sign-in or age restriction, offline/interrupted network, 403/client validation, helper incompatibility, output permission, disk full, generic download, merge/conversion, and persistence recovery. Keep raw details only in `ErrorDetailsView` after diagnostic sanitization.

- [ ] **Step 4: Run localization tests and inspect all three languages**

Run: `cd swift-2.0 && swift test --filter LocalizationTests`

Expected: PASS.

Run: `cd swift-2.0 && swift run YTDownloaderPro2`

Expected: manually switching each language updates visible labels without restart and without overlap at the minimum window size.

- [ ] **Step 5: Commit localization**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Resources swift-2.0/Sources/YTDownloaderPro2/Models/DownloadError.swift swift-2.0/Sources/YTDownloaderPro2/Views swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift
git commit -m "feat(swift): localize interface and recovery errors"
```

### Task 14: Split macOS Update Manifest And Update Checker

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/UpdateChecker.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/UpdateCheckerTests.swift`
- Create: `updates/macos.json`
- Create: `updates/windows.json`
- Create: `scripts/create_macos_manifest.py`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift`
- Modify: `ytdp/app.py`
- Modify: `ytdp/updater.py`
- Modify: `tests/test_updater.py`
- Modify: `tests/test_version_sources.py`

**Interfaces:**
- Produces: `MacOSUpdateManifest` and `UpdateResult.upToDate`, `.available`, `.unsupportedOS`, `.failed`.
- Produces: `UpdateChecker.check(manual:) async -> UpdateResult` using an injected URL session.

- [ ] **Step 1: Write manifest isolation and version comparison tests**

```swift
final class UpdateCheckerTests: XCTestCase {
    func testMacAppAcceptsOnlyMacOSManifest() async {
        let checker = UpdateChecker.fixture(response: .windowsManifest)
        let result = await checker.check(manual: true)
        XCTAssertEqual(result, .failed(.wrongPlatformManifest))
    }

    func testSemanticVersionComparisonFindsTwoPointZeroOne() async {
        let checker = UpdateChecker.fixture(current: "2.0.0", latest: "2.0.1")
        let result = await checker.check(manual: true)
        XCTAssertTrue(result.isAvailable)
    }

    func testAutomaticTransientFailureIsSilentButManualIsActionable() async {
        let checker = UpdateChecker.fixture(error: URLError(.timedOut))
        let automaticResult = await checker.check(manual: false)
        let manualResult = await checker.check(manual: true)
        XCTAssertEqual(automaticResult, .failed(.silentTransient))
        XCTAssertEqual(manualResult, .failed(.actionableNetwork))
    }
}
```

- [ ] **Step 2: Run and verify update types are missing**

Run: `cd swift-2.0 && swift test --filter UpdateCheckerTests`

Expected: FAIL.

- [ ] **Step 3: Implement Contents API decoding and manifest generation**

Decode the GitHub Contents API base64 body, then decode `MacOSUpdateManifest`. Require `platform == "macos"`, semantic version fields, HTTPS URLs, a 64-character lowercase SHA-256, and `minimumMacOS`. The Python generator receives version, release URL, download URL, checksum, publication timestamp, and release notes as explicit arguments and writes deterministic JSON.

Add platform-aware manifest parsing to `ytdp/updater.py` and point future Windows Python builds at the GitHub Contents API path for `updates/windows.json`. Preserve `version.txt` only as a compatibility source for already-released clients; new macOS Swift code must not read it. Add Python regression tests proving the Windows client rejects a `platform: macos` manifest and selects only a Windows x64 release asset.

- [ ] **Step 4: Run Swift tests and validate both JSON files**

Run: `cd swift-2.0 && swift test --filter UpdateCheckerTests`

Expected: PASS.

Run: `python3 -m json.tool updates/macos.json`

Expected: valid JSON with `platform: macos`.

Run: `python3 -m json.tool updates/windows.json`

Expected: valid JSON with `platform: windows`.

Run: `python3 -m unittest tests.test_updater tests.test_version_sources -v`

Expected: PASS with Windows manifest isolation and legacy `version.txt` compatibility covered.

- [ ] **Step 5: Commit split updates**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Services/UpdateChecker.swift swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift swift-2.0/Tests/YTDownloaderPro2Tests/UpdateCheckerTests.swift updates scripts/create_macos_manifest.py ytdp/app.py ytdp/updater.py tests/test_updater.py tests/test_version_sources.py
git commit -m "feat: split macOS and Windows update manifests"
```

### Task 15: Build, Bundle Verification, And Release Checklist

**Files:**
- Create: `scripts/build_swift_2.sh`
- Create: `scripts/check_swift_bundle.py`
- Create: `tests/test_swift_bundle.py`
- Create: `docs/SWIFT_2_TEST_CHECKLIST.md`
- Modify: `README.md`
- Modify: `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Consumes: the SwiftPM release executable, `AppIcon.icns`, and helpers under `tools/`.
- Produces: `dist/YT Downloader Pro 2.app`, an unsigned ZIP for internal testing, and machine-readable bundle verification output.

- [ ] **Step 1: Write bundle verifier tests before the build script**

Create Python `unittest` cases in `tests/test_swift_bundle.py` that build a temporary fake bundle and assert:

```python
def test_rejects_duplicate_physical_ffmpeg(self):
    bundle = self.fake_bundle()
    self.add_helper(bundle, "ffmpeg")
    self.add_helper(bundle, "Frameworks/ffmpeg")
    report = verify_bundle(bundle)
    self.assertTrue(any("duplicate" in error.lower() for error in report.errors))

def test_requires_all_four_helpers(self):
    bundle = self.fake_bundle(helpers=("yt-dlp_macos", "ffmpeg", "ffprobe"))
    report = verify_bundle(bundle)
    self.assertTrue(any("qjs" in error for error in report.errors))
```

- [ ] **Step 2: Run verifier tests and confirm failure**

Run: `python3 -m unittest tests.test_swift_bundle -v`

Expected: FAIL because `verify_bundle` is missing.

- [ ] **Step 3: Implement deterministic app assembly and verification**

`build_swift_2.sh` must:

1. Run `swift test`.
2. Build the release executable for the requested architecture set.
3. Create `Contents/MacOS`, `Contents/Helpers`, and `Contents/Resources`.
4. Copy exactly one executable plus the four helpers.
5. Copy icon, localized resources, Info.plist, and third-party notices.
6. Set executable permissions and remove quarantine from build inputs.
7. Ad-hoc sign helpers first and the app last for internal builds.
8. Run `check_swift_bundle.py` before producing the ZIP.

The verifier resolves symlinks and inode/device pairs, executes every version command from inside the bundle, checks FFmpeg/FFprobe version agreement, checks required architecture slices with `lipo`, checks Info.plist version values, and emits nonzero status on any error.

- [ ] **Step 4: Run full automated and packaging verification**

Run: `cd swift-2.0 && swift test`

Expected: PASS.

Run: `python3 -m unittest tests.test_swift_bundle -v`

Expected: PASS.

Run: `./scripts/build_swift_2.sh --version 2.0.0 --unsigned-test`

Expected: creates `dist/YT Downloader Pro 2.app` and an unsigned internal-test ZIP, then reports one physical copy and successful execution for every helper.

Run: `codesign --verify --deep --strict --verbose=2 'dist/YT Downloader Pro 2.app'`

Expected: valid ad-hoc internal signature.

- [ ] **Step 5: Document real-device acceptance and commit packaging**

The checklist must contain explicit rows for macOS 13+, Apple Silicon, Intel, single video, multiple URLs, playlist, MP4, MP3, best and selected quality, subtitles, thumbnail, cookies opt-in, concurrency 1/5/10, pause/resume, quit recovery, cancel cleanup, retry, duplicate names, custom folder permission, offline, 403, unavailable media, disk full, FFmpeg failure, all three languages, Gatekeeper, notarization, DMG, manifest checksum, tag, and GitHub Release alignment.

```bash
git add scripts/build_swift_2.sh scripts/check_swift_bundle.py tests/test_swift_bundle.py docs/SWIFT_2_TEST_CHECKLIST.md README.md THIRD_PARTY_NOTICES.md
git commit -m "build(swift): package and verify macOS 2.0 app"
```

## Final Verification Gate

- [ ] Run all Python regression tests to prove Swift work did not break the Windows/Python line.

Run: `python3 -m unittest discover -s tests -v`

Expected: PASS.

- [ ] Run the complete Swift suite.

Run: `cd swift-2.0 && swift test`

Expected: PASS.

- [ ] Build and verify the unsigned internal app.

Run: `./scripts/build_swift_2.sh --version 2.0.0 --unsigned-test`

Expected: PASS with app and ZIP paths printed.

- [ ] Inspect the Git diff and commit history for unrelated changes or missing task commits.

Run: `git status --short`

Expected: no uncommitted files.

Run: `git log --oneline --decorate -20`

Expected: one focused commit per completed task plus the design and plan commits.
