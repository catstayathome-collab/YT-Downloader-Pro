import Foundation
import XCTest
@testable import YTDownloaderPro2

@MainActor
final class DownloadStoreTests: XCTestCase {
    func testPlaylistBatchCreatesOneQueuedJobPerSelectedEntry() async throws {
        let fixture = try StoreFixture(analysis: .playlist(.fixture(entryCount: 3)))
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/playlist")
        await fixture.store.addPlaylistEntries(selectedIDs: ["1", "3"], options: .defaults)

        XCTAssertEqual(fixture.store.jobs.map(\.status), [.queued, .queued])
        XCTAssertEqual(fixture.store.jobs.map(\.sourceURL), [
            "https://youtube.test/watch?v=1",
            "https://youtube.test/watch?v=3"
        ])
    }

    func testOnlyQueuedJobCanBeEdited() async throws {
        let fixture = try StoreFixture(jobs: [.fixture(status: .queued), .fixture(status: .paused)])
        defer { fixture.cleanUp() }

        let queuedWasEdited = await fixture.store.editQueuedJob(
            fixture.store.jobs[0].id,
            options: .fixture(outputKind: .mp3)
        )
        let pausedWasEdited = await fixture.store.editQueuedJob(
            fixture.store.jobs[1].id,
            options: .fixture(outputKind: .mp3)
        )

        XCTAssertTrue(queuedWasEdited)
        XCTAssertFalse(pausedWasEdited)
        XCTAssertEqual(fixture.store.jobs[0].options.outputKind, .mp3)
        XCTAssertEqual(fixture.store.jobs[1].options.outputKind, .mp4)
    }

    func testRemoveCompletedRecordKeepsMediaFile() async throws {
        let completed = try StoreFixture.completedJobWithMedia()
        defer { completed.fixture.cleanUp() }

        await completed.fixture.store.removeRecord(completed.job.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.mediaURL.path))
        XCTAssertFalse(completed.fixture.store.jobs.contains(where: { $0.id == completed.job.id }))
    }

    func testRestoreConvertsInterruptedJobsToPausedWithoutStartingThem() async throws {
        let jobs: [DownloadJob] = [
            .fixture(status: .analyzing),
            .fixture(status: .downloading),
            .fixture(status: .merging),
            .fixture(status: .queued),
            .fixture(status: .completed)
        ]
        let fixture = try StoreFixture(jobs: jobs)
        defer { fixture.cleanUp() }

        XCTAssertEqual(fixture.store.jobs.map(\.status), [.paused, .paused, .paused, .queued, .completed])
        let startedIDs = await fixture.runner.startedIDs()
        XCTAssertEqual(startedIDs, [])
    }

    func testRetryReanalyzesBeforeRequeueingWithOriginalOptions() async throws {
        let originalOptions = DownloadOptions.fixture(outputKind: .mp3)
        let failedJob = DownloadJob.fixture(status: .failed, outputKind: .mp3)
        let analysis = AnalysisRecorder(result: .video(.fixture(sourceURL: failedJob.sourceURL)))
        let fixture = try StoreFixture(jobs: [failedJob], analysis: { url, options in
            try await analysis.analyze(url: url, options: options)
        })
        defer { fixture.cleanUp() }

        await fixture.store.retry(failedJob.id)

        let requestedURLs = await analysis.recordedURLs()
        XCTAssertEqual(requestedURLs, [failedJob.sourceURL])
        XCTAssertEqual(fixture.store.jobs[0].status, .queued)
        XCTAssertEqual(fixture.store.jobs[0].retryCount, 1)
        XCTAssertEqual(fixture.store.jobs[0].options, originalOptions)
    }

    func testQueueChangesPersistImmediately() async throws {
        let fixture = try StoreFixture(analysis: .video(.fixture()))
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/video")
        await fixture.store.addVideo(options: .defaults)

        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.map(\.status), [.queued])
    }

    func testPrepareToQuitPersistsPausedActiveJobAfterCoordinatorShutdown() async throws {
        let activeJob = DownloadJob.fixture(status: .downloading)
        let fixture = try StoreFixture(jobs: [activeJob])
        defer { fixture.cleanUp() }

        await fixture.store.prepareToQuit()

        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.map(\.status), [.paused])
    }

    func testPrepareToQuitWaitsForRunningJobToBePersistedAsPaused() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)
        await fixture.runner.emit(.phase(.downloading), for: job.id)
        try await waitUntil("store to receive the downloading phase") {
            fixture.store.jobs.first?.status == .downloading
        }

        await fixture.store.prepareToQuit()

        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.map(\.status), [.paused])
    }

    func testPrepareToQuitConvertsMergingJobToRestartablePausedState() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)
        await fixture.runner.emit(.phase(.merging), for: job.id)
        try await waitUntil("store to receive the merging phase") {
            fixture.store.jobs.first?.status == .merging
        }

        await fixture.store.prepareToQuit()

        XCTAssertEqual(fixture.store.jobs.map(\.status), [.paused])
    }

    func testCancelStopsJobAlreadyStartedBeforeItsFirstPhaseEvent() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)
        await fixture.store.cancel(job.id)

        let cancelledIDs = await fixture.runner.cancelledIDs()
        XCTAssertEqual(cancelledIDs, [job.id])
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut(description)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private final class StoreFixture {
    let root: URL
    let runner: StoreRunner
    let coordinator: DownloadCoordinator
    let persistence: PersistenceController
    let store: DownloadStore

    init(
        jobs: [DownloadJob] = [],
        analysis: AnalysisResult = .video(.fixture())
    ) throws {
        root = try temporaryDirectory()
        runner = StoreRunner()
        coordinator = DownloadCoordinator(limit: 1, runner: runner)
        persistence = PersistenceController(root: root)
        store = DownloadStore(
            jobs: jobs,
            coordinator: coordinator,
            persistence: persistence,
            thumbnailCache: ThumbnailCache(root: root),
            diagnostics: DiagnosticsLogger(root: root),
            analyze: { _, _ in analysis }
        )
    }

    init(jobs: [DownloadJob], analysis: @escaping @Sendable (String, DownloadOptions) async throws -> AnalysisResult) throws {
        root = try temporaryDirectory()
        runner = StoreRunner()
        coordinator = DownloadCoordinator(limit: 1, runner: runner)
        persistence = PersistenceController(root: root)
        store = DownloadStore(
            jobs: jobs,
            coordinator: coordinator,
            persistence: persistence,
            thumbnailCache: ThumbnailCache(root: root),
            diagnostics: DiagnosticsLogger(root: root),
            analyze: analysis
        )
    }

    static func completedJobWithMedia() throws -> (fixture: StoreFixture, job: DownloadJob, mediaURL: URL) {
        let directory = try temporaryDirectory()
        let mediaURL = directory.appendingPathComponent("finished.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let job = DownloadJob.fixture(status: .completed, outputURL: mediaURL)
        let fixture = try StoreFixture(jobs: [job])
        return (fixture, job, mediaURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor StoreRunner: JobRunning {
    private var starts: [UUID] = []
    private var cancellations: [UUID] = []
    private var continuations: [UUID: AsyncThrowingStream<DownloadEvent, Error>.Continuation] = [:]

    nonisolated func events(for job: DownloadJob) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.recordStart(job.id, continuation: continuation) }
        }
    }

    func startedIDs() -> [UUID] { starts }

    func pause(jobID: UUID) async { finish(jobID) }
    func cancel(jobID: UUID) async {
        cancellations.append(jobID)
        finish(jobID)
    }
    func interruptForQuit(jobID: UUID) async { finish(jobID) }

    func emit(_ event: DownloadEvent, for jobID: UUID) {
        continuations[jobID]?.yield(event)
    }

    func waitForStart(of jobID: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !starts.contains(jobID) {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("runner to start \(jobID)")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func cancelledIDs() -> [UUID] { cancellations }

    private func recordStart(
        _ jobID: UUID,
        continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
    ) {
        starts.append(jobID)
        continuations[jobID] = continuation
    }

    private func finish(_ jobID: UUID) {
        continuations.removeValue(forKey: jobID)?.finish()
    }
}

private actor AnalysisRecorder {
    private let result: AnalysisResult
    private var requestedURLs: [String] = []

    init(result: AnalysisResult) {
        self.result = result
    }

    func analyze(url: String, options: DownloadOptions) async throws -> AnalysisResult {
        requestedURLs.append(url)
        return result
    }

    func recordedURLs() -> [String] { requestedURLs }
}

private extension VideoAnalysis {
    static func fixture(sourceURL: String = "https://youtube.test/video") -> VideoAnalysis {
        VideoAnalysis(
            sourceURL: sourceURL,
            title: "Fixture video",
            duration: 30,
            thumbnailURL: nil,
            videoFormats: [],
            audioFormats: []
        )
    }
}

private extension PlaylistAnalysis {
    static func fixture(entryCount: Int) -> PlaylistAnalysis {
        PlaylistAnalysis(
            id: "playlist",
            title: "Fixture playlist",
            entries: (1...entryCount).map { index in
                PlaylistEntry(
                    id: "\(index)",
                    sourceURL: "https://youtube.test/watch?v=\(index)",
                    title: "Entry \(index)",
                    duration: 30,
                    thumbnailURL: nil
                )
            }
        )
    }
}

private enum StoreTestWaitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case let .timedOut(description):
            description
        }
    }
}
