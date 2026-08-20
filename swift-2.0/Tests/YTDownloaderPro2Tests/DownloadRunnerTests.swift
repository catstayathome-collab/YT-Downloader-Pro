import Foundation
import XCTest
@testable import YTDownloaderPro2

final class DownloadRunnerTests: XCTestCase {
    func testSuccessfulRunEmitsReservedBasenameAndVerifiedCompletionInOrder() async throws {
        // Completing from exit code without a reserved, existing final file would make this pass incorrectly.
        let fixture = try RunnerFixture(mode: "success")
        let events = try await collect(fixture.runner.events(for: fixture.job()))

        XCTAssertEqual(events.compactMap(phase), [.analyzing, .downloading, .merging])
        XCTAssertEqual(events.compactMap(reservedBasename).count, 1)
        XCTAssertEqual(events.last, .completed)
        XCTAssertTrue(events.contains(.output(fixture.finalURL)))
        XCTAssertEqual(fixture.scope.startCount, 1)
        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testExitZeroWithoutOwnedFinalOutputFailsInsteadOfCompleting() async throws {
        // Removing final-output verification would emit completed for this zero-exit process.
        let fixture = try RunnerFixture(mode: "no-final")

        do {
            _ = try await collect(fixture.runner.events(for: fixture.job()))
            XCTFail("Expected missing-final-output failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .unknown)
        }
        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testPausePreservesPartAndMarkerAndResumeReusesBasenameWithContinue() async throws {
        // Releasing a paused reservation or omitting --continue would lose resumable ownership.
        let fixture = try RunnerFixture(mode: "pause")
        let initialJob = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: initialJob)) }
        try await fixture.waitForFile(fixture.partURL)

        await fixture.runner.pause(jobID: initialJob.id)
        let pausedEvents = try await task.value

        let basename = try XCTUnwrap(pausedEvents.compactMap(reservedBasename).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))

        let resumeJob = fixture.job(id: initialJob.id, reservedBasename: basename)
        let resumed = Task { try await collect(fixture.runner.events(for: resumeJob)) }
        try await fixture.waitForTraceLines(2)
        await fixture.runner.cancel(jobID: initialJob.id)
        _ = try await resumed.value

        XCTAssertTrue(fixture.commandLog().contains("--continue"))
    }

    func testPauseDuringMergeIsRejectedAndLeavesProcessRunning() async throws {
        // Interrupting a merger through an ordinary pause would destroy a non-resumable output.
        let fixture = try RunnerFixture(mode: "merge")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.finalURL)

        await fixture.runner.pause(jobID: job.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertEqual(fixture.traceLines().filter { $0 == "download" }.count, 1)
        await fixture.runner.cancel(jobID: job.id)
        _ = try await task.value
    }

    func testCancelRemovesOnlyOwnedIncompleteArtifactsAndMarker() async throws {
        // Prefix or glob cleanup would remove the foreign file or completed media in this fixture.
        let fixture = try RunnerFixture(mode: "cancel")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)
        let basename = "Example video"

        await fixture.runner.cancel(jobID: job.id)
        _ = try await task.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.formatURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.foreignPartURL.path))
    }

    func testQuitDuringMergeDeletesOnlyIncompleteDestinationAndPreservesSourcePartial() async throws {
        // Treating quit like cancel would erase resumable source streams.
        let fixture = try RunnerFixture(mode: "merge")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.finalURL)
        let basename = "Example video"

        await fixture.runner.interruptForQuit(jobID: job.id)
        _ = try await task.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.formatPartURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))
    }

    func testRetryable403ReanalyzesBeforeOneBoundedRetry() async throws {
        // Retrying every failure or skipping reanalysis would change the trace and phase sequence.
        let fixture = try RunnerFixture(mode: "retry-403")
        let events = try await collect(fixture.runner.events(for: fixture.job()))

        XCTAssertEqual(events.compactMap(phase), [.analyzing, .downloading, .analyzing, .downloading])
        XCTAssertEqual(fixture.traceLines(), ["download", "download"])
        XCTAssertEqual(fixture.analysisTraceLines(), ["analysis"])
    }

    func testArbitraryFailureDoesNotRetry() async throws {
        // Broad retry matching would run the fake downloader a second time.
        let fixture = try RunnerFixture(mode: "arbitrary-error")

        do {
            _ = try await collect(fixture.runner.events(for: fixture.job()))
            XCTFail("Expected a download failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .unknown)
        }
        XCTAssertEqual(fixture.traceLines(), ["download"])
    }

    func testMissingSavedFormatAfterReanalysisRequiresReselection() async throws {
        // Silently accepting a reanalysis without the saved format would download changed quality.
        let fixture = try RunnerFixture(mode: "missing-format")

        do {
            _ = try await collect(fixture.runner.events(for: fixture.job(videoFormatID: "137")))
            XCTFail("Expected format reselection failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .formatReselectionRequired)
        }
        XCTAssertEqual(fixture.traceLines(), ["download"])
        XCTAssertEqual(fixture.analysisTraceLines(), ["analysis"])
    }

    func testDuplicateRunAndConsumerCancellationDoNotLeakProcessOrScope() async throws {
        // Forgetting stream-termination cleanup leaves the helper and its security scope alive.
        let fixture = try RunnerFixture(mode: "consumer-cancel")
        let job = fixture.job()
        let first = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)

        do {
            _ = try await collect(fixture.runner.events(for: job))
            XCTFail("Expected duplicate active job failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .unknown)
        }

        first.cancel()
        _ = await first.result
        try await fixture.waitForScopeStop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertEqual(fixture.scope.startCount, 1)
        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testLaunchFailureReleasesScopeAndReservation() async throws {
        // A pre-launch failure must not retain a marker or security-scoped folder access.
        let fixture = try RunnerFixture(mode: "success", launchable: false)
        let job = fixture.job()

        do {
            _ = try await collect(fixture.runner.events(for: job))
            XCTFail("Expected launch failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .bundledDownloaderUnavailable)
        }
        XCTAssertEqual(fixture.scope.startCount, 1)
        XCTAssertEqual(fixture.scope.stopCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasSuffix(".ytdp-reservation") })
    }

    private func phase(_ event: DownloadEvent) -> DownloadPhase? {
        guard case let .phase(value) = event else { return nil }
        return value
    }

    private func reservedBasename(_ event: DownloadEvent) -> String? {
        guard case let .reservedBasename(value) = event else { return nil }
        return value
    }
}

private final class RunnerFixture: @unchecked Sendable {
    let directory: URL
    let executable: URL
    let scope = SecurityScopeRecorder()
    let runner: DownloadRunner

    init(mode: String, launchable: Bool = true) throws {
        directory = try temporaryDirectory()
        let fixtureExecutable = try Self.copyFixtureScript(to: directory)
        if !launchable {
            executable = directory.appendingPathComponent("missing-yt-dlp")
        } else {
            executable = fixtureExecutable
        }
        let bookmarks = OutputDirectoryBookmarkService(
            makeBookmark: { _ in Data("fixture-bookmark".utf8) },
            resolveBookmark: { [directory] _ in .init(url: directory, isStale: false) },
            startAccessingSecurityScopedResource: { [scope] _ in
                scope.startCount += 1
                return true
            },
            stopAccessingSecurityScopedResource: { [scope] _ in scope.stopCount += 1 }
        )
        let toolchain = Toolchain(ytDLP: executable, ffmpeg: executable, ffprobe: executable, qjs: executable)
        runner = DownloadRunner(
            toolchain: toolchain,
            allocator: OutputNameAllocator(),
            metadataProbe: MetadataProbe(toolchain: toolchain, processRunner: SystemProcessLauncher()),
            bookmarks: bookmarks,
            interruptGraceNanoseconds: 100_000_000
        )
        try "mode=\(mode)".write(to: directory.appendingPathComponent("fixture-mode"), atomically: true, encoding: .utf8)
    }

    var finalURL: URL { directory.appendingPathComponent("Example video.mp4") }
    var partURL: URL { directory.appendingPathComponent("Example video.mp4.part") }
    var formatURL: URL { directory.appendingPathComponent("Example video.f137.mp4") }
    var formatPartURL: URL { directory.appendingPathComponent("Example video.f137.mp4.part") }
    var foreignPartURL: URL { directory.appendingPathComponent("Foreign.mp4.part") }

    func job(id: UUID = UUID(), reservedBasename: String? = nil, videoFormatID: String? = nil) -> DownloadJob {
        var options = DownloadOptions.fixture()
        options.outputDirectoryBookmark = Data("fixture-bookmark".utf8)
        options.outputDirectoryDisplayPath = directory.path
        if let videoFormatID {
            options.videoQuality = .format(id: videoFormatID, label: "fixture")
        }
        let mode = (try? String(contentsOf: directory.appendingPathComponent("fixture-mode"), encoding: .utf8))?.replacingOccurrences(of: "mode=", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "success"
        return DownloadJob(
            id: id,
            sourceURL: "https://fake.test/\(mode)?state=\(directory.path)",
            title: "Example video",
            reservedOutputBasename: reservedBasename,
            options: options
        )
    }

    func markerURL(basename: String) -> URL {
        directory.appendingPathComponent(".\(basename).ytdp-reservation")
    }

    func traceLines() -> [String] {
        (try? String(contentsOf: directory.appendingPathComponent("Example video.fake-trace"), encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init) ?? []
    }

    func trace() -> String {
        (try? String(contentsOf: directory.appendingPathComponent("Example video.fake-trace"), encoding: .utf8)) ?? ""
    }

    func commandLog() -> String {
        (try? String(contentsOf: directory.appendingPathComponent("Example video.fake-command"), encoding: .utf8)) ?? ""
    }

    func analysisTraceLines() -> [String] {
        (try? String(contentsOf: directory.appendingPathComponent("analysis.fake-trace"), encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init) ?? []
    }

    func waitForFile(_ url: URL) async throws {
        try await waitUntil { FileManager.default.fileExists(atPath: url.path) }
    }

    func waitForTraceLines(_ count: Int) async throws {
        try await waitUntil { self.traceLines().count >= count }
    }

    func waitForScopeStop() async throws {
        try await waitUntil { self.scope.stopCount == 1 }
    }

    private static func copyFixtureScript(to directory: URL) throws -> URL {
        guard let source = Bundle.module.url(forResource: "fake-yt-dlp", withExtension: "sh") else {
            throw NSError(domain: "RunnerFixture", code: 1)
        }
        let destination = directory.appendingPathComponent("fake-yt-dlp.sh")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw NSError(domain: "RunnerFixture", code: 2)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class SecurityScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int {
        get { lock.withLock { starts } }
        set { lock.withLock { starts = newValue } }
    }

    var stopCount: Int {
        get { lock.withLock { stops } }
        set { lock.withLock { stops = newValue } }
    }
}
