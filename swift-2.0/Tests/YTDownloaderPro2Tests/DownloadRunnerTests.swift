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
        let finalProgress = events.compactMap { event -> JobProgress? in
            guard case let .progress(progress) = event else { return nil }
            return progress
        }.last
        XCTAssertEqual(
            finalProgress,
            JobProgress(
                fraction: 1,
                downloadedBytes: 7,
                totalBytes: 7,
                bytesPerSecond: nil,
                etaSeconds: 0
            )
        )
        XCTAssertEqual(fixture.scope.startCount, 1)
        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testDownloadArgumentsUseResolvedReservationDirectoryInsteadOfDisplayPath() async throws {
        // Clearing outputURL after reservation would send yt-dlp to this stale display path.
        let fixture = try RunnerFixture(mode: "success", displayDirectory: "/tmp/stale-display-directory")
        _ = try await collect(fixture.runner.events(for: fixture.job()))

        XCTAssertTrue(fixture.commandLog().contains("\(fixture.directory.path)/Example video.%(ext)s"))
        XCTAssertFalse(fixture.commandLog().contains("/tmp/stale-display-directory"))
    }

    func testExitZeroWithoutOwnedFinalOutputFailsInsteadOfCompleting() async throws {
        // Removing final-output verification would emit completed for this zero-exit process.
        let fixture = try RunnerFixture(mode: "no-final")

        do {
            _ = try await collect(fixture.runner.events(for: fixture.job()))
            XCTFail("Expected missing-final-output failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .downloadFailed)
        }
        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testDownloadFailuresUseStableActionableCategories() async throws {
        let cases: [(String, DownloadFailure.Category)] = [
            ("permission-error", .outputPermissionDenied),
            ("disk-full", .diskFull),
            ("postprocess-error", .postProcessingFailed)
        ]

        for (mode, expected) in cases {
            let fixture = try RunnerFixture(mode: mode)
            do {
                _ = try await collect(fixture.runner.events(for: fixture.job()))
                XCTFail("Expected \(expected)")
            } catch let failure as DownloadFailure {
                XCTAssertEqual(failure.category, expected, mode)
            }
        }
    }

    func testPausePreservesPartAndMarkerAndResumeReusesBasenameWithContinue() async throws {
        // Releasing a paused reservation or omitting --continue would lose resumable ownership.
        let fixture = try RunnerFixture(mode: "pause")
        let initialJob = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: initialJob)) }
        try await fixture.waitForFile(fixture.partURL)

        let pauseAccepted = await fixture.runner.pause(jobID: initialJob.id)
        let pausedEvents = try await task.value

        XCTAssertTrue(pauseAccepted)
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
        let events = EventRecorder()
        let task = Task { () throws -> [DownloadEvent] in
            var collected: [DownloadEvent] = []
            for try await event in fixture.runner.events(for: job) {
                collected.append(event)
                await events.record(event)
            }
            return collected
        }
        await events.wait(for: .phase(.merging))

        let pauseAccepted = await fixture.runner.pause(jobID: job.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(pauseAccepted)
        XCTAssertEqual(fixture.traceLines().filter { $0 == "download" }.count, 1)
        await fixture.runner.cancel(jobID: job.id)
        _ = try await task.value
    }

    func testPauseDuringPostprocessingIsRejectedAndLeavesProcessRunning() async throws {
        let fixture = try RunnerFixture(mode: "postprocess")
        let job = fixture.job()
        let events = EventRecorder()
        let task = Task { () throws -> [DownloadEvent] in
            var collected: [DownloadEvent] = []
            for try await event in fixture.runner.events(for: job) {
                collected.append(event)
                await events.record(event)
            }
            return collected
        }
        await events.wait(for: .phase(.postprocessing))

        let pauseAccepted = await fixture.runner.pause(jobID: job.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(pauseAccepted)
        XCTAssertEqual(fixture.traceLines().filter { $0 == "download" }.count, 1)
        await fixture.runner.cancel(jobID: job.id)
        _ = try await task.value
    }

    func testCancelRemovesOnlyOwnedIncompleteArtifactsAndMarker() async throws {
        // Prefix or glob cleanup would remove the foreign file or completed media in this fixture.
        let fixture = try RunnerFixture(mode: "cancel")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.foreignPartURL)
        let basename = "Example video"

        await fixture.runner.cancel(jobID: job.id)
        _ = try await task.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.formatURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.formatPartFragmentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.formatYTDLURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.foreignPartURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.foreignFragmentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.invalidFragmentURL.path))
    }

    func testCancelWaitsForTerminationAndSkipsCleanupWhenReservationOwnershipIsReplaced() async throws {
        // Deleting before an ownership check would remove these artifacts after the marker is replaced.
        let fixture = try RunnerFixture(mode: "cancel")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)
        let foreignID = UUID()
        try foreignID.uuidString.write(to: fixture.markerURL(basename: "Example video"), atomically: true, encoding: .utf8)

        await fixture.runner.cancel(jobID: job.id)
        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.formatURL.path))
        XCTAssertEqual(try String(contentsOf: fixture.markerURL(basename: "Example video"), encoding: .utf8), foreignID.uuidString)
    }

    func testRepeatedCancelCallsShareTerminalCleanup() async throws {
        // A second caller must wait for the same cleanup instead of racing scope release or deadlocking the actor.
        let fixture = try RunnerFixture(mode: "cancel")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)

        async let first: Void = fixture.runner.cancel(jobID: job.id)
        async let second: Void = fixture.runner.cancel(jobID: job.id)
        _ = await (first, second)

        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partURL.path))
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

        XCTAssertEqual(fixture.scope.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.formatPartURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))
    }

    func testQuitWaitsForMergeTerminationBeforeReturning() async throws {
        // Returning after only INT leaves the scoped folder and incomplete merge output live.
        let fixture = try RunnerFixture(mode: "merge-ignore-int")
        let job = fixture.job(videoFormatID: "137")
        let events = EventRecorder()
        let task = Task { () throws -> [DownloadEvent] in
            var collected: [DownloadEvent] = []
            for try await event in fixture.runner.events(for: job) {
                collected.append(event)
                await events.record(event)
            }
            return collected
        }
        await events.wait(for: .phase(.merging))

        await fixture.runner.interruptForQuit(jobID: job.id)

        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value
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
            XCTAssertEqual(failure.category, .downloadFailed)
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
            XCTAssertEqual(failure.category, .downloadFailed)
        }

        first.cancel()
        _ = await first.result
        try await fixture.waitForScopeStop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertEqual(fixture.scope.startCount, 1)
        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testCancelStopsTrackedReanalysisBeforeReturning() async throws {
        // Calling MetadataProbe through opaque run leaves this reanalysis process outside cancellation control.
        let fixture = try RunnerFixture(mode: "retry-analysis-wait")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.analysisStartedURL)

        try await completeWithin(nanoseconds: 1_500_000_000) {
            await fixture.runner.cancel(jobID: job.id)
        }
        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value

        XCTAssertEqual(fixture.traceLines(), ["download"])
    }

    func testConsumerCancellationStopsTrackedReanalysis() async throws {
        // A cancelled stream consumer must interrupt the analysis helper, not only detach from its events.
        let fixture = try RunnerFixture(mode: "retry-analysis-wait")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.analysisStartedURL)

        task.cancel()
        _ = await task.result
        try await fixture.waitForScopeStop(timeoutNanoseconds: 1_500_000_000)

        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testPauseStopsTrackedReanalysis() async throws {
        // Treating reanalysis as an opaque probe would leave its helper alive after a pause.
        let fixture = try RunnerFixture(mode: "retry-analysis-wait")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.analysisStartedURL)

        let pauseAccepted = await fixture.runner.pause(jobID: job.id)
        _ = try await task.value

        XCTAssertTrue(pauseAccepted)
        XCTAssertEqual(fixture.scope.stopCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: "Example video").path))
    }

    func testQuitWaitsForTrackedReanalysisTermination() async throws {
        // Quit must not return while a retry-analysis helper still owns the security scope.
        let fixture = try RunnerFixture(mode: "retry-analysis-wait")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.analysisStartedURL)

        await fixture.runner.interruptForQuit(jobID: job.id)

        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: "Example video").path))
    }

    func testPauseEscalatesToTerminationWhenHelperIgnoresInterrupt() async throws {
        // Sending only INT leaves this helper running forever.
        let fixture = try RunnerFixture(mode: "ignore-int")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)

        let pauseAccepted = await fixture.runner.pause(jobID: job.id)
        _ = try await task.value

        XCTAssertTrue(pauseAccepted)
        XCTAssertEqual(fixture.scope.stopCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
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

    init(mode: String, launchable: Bool = true, displayDirectory: String? = nil) throws {
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
        if let displayDirectory {
            try displayDirectory.write(to: directory.appendingPathComponent("fixture-display-directory"), atomically: true, encoding: .utf8)
        }
    }

    var finalURL: URL { directory.appendingPathComponent("Example video.mp4") }
    var partURL: URL { directory.appendingPathComponent("Example video.mp4.part") }
    var formatURL: URL { directory.appendingPathComponent("Example video.f137.mp4") }
    var formatPartURL: URL { directory.appendingPathComponent("Example video.f137.mp4.part") }
    var formatPartFragmentURL: URL { directory.appendingPathComponent("Example video.f137.mp4.part-Frag1") }
    var formatYTDLURL: URL { directory.appendingPathComponent("Example video.f137.mp4.ytdl") }
    var invalidFragmentURL: URL { directory.appendingPathComponent("Example video.f137.mp4.part-FragNotANumber") }
    var foreignPartURL: URL { directory.appendingPathComponent("Foreign.mp4.part") }
    var foreignFragmentURL: URL { directory.appendingPathComponent("Example video2.f137.mp4.part-Frag1") }
    var analysisStartedURL: URL { directory.appendingPathComponent("analysis-started") }

    func job(id: UUID = UUID(), reservedBasename: String? = nil, videoFormatID: String? = nil) -> DownloadJob {
        var options = DownloadOptions.fixture()
        options.outputDirectoryBookmark = Data("fixture-bookmark".utf8)
        options.outputDirectoryDisplayPath = (try? String(contentsOf: directory.appendingPathComponent("fixture-display-directory"), encoding: .utf8)) ?? directory.path
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

    func waitForScopeStop(timeoutNanoseconds: UInt64 = 3_000_000_000) async throws {
        try await waitUntil(timeoutNanoseconds: timeoutNanoseconds) { self.scope.stopCount == 1 }
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

private actor EventRecorder {
    private var events: [DownloadEvent] = []
    private var waiters: [(DownloadEvent, CheckedContinuation<Void, Never>)] = []

    func record(_ event: DownloadEvent) {
        events.append(event)
        let matching = waiters.enumerated().filter { $0.element.0 == event }.map(\.offset)
        for index in matching.reversed() {
            waiters.remove(at: index).1.resume()
        }
    }

    func wait(for event: DownloadEvent) async {
        guard !events.contains(event) else { return }
        await withCheckedContinuation { continuation in
            waiters.append((event, continuation))
        }
    }
}

private func completeWithin<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let state = RunnerTimeoutState(continuation: continuation)
        Task.detached {
            do {
                state.resume(with: .success(try await operation()))
            } catch {
                state.resume(with: .failure(error))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(nanoseconds) / 1_000_000_000) {
            state.resume(with: .failure(RunnerTimeoutError.timedOut))
        }
    }
}

private final class RunnerTimeoutState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private enum RunnerTimeoutError: Error {
    case timedOut
}
