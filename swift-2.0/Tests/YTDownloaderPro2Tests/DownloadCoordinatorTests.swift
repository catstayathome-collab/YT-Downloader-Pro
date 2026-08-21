import Foundation
import XCTest
@testable import YTDownloaderPro2

final class DownloadCoordinatorTests: XCTestCase {
    func testDefaultLimitStartsExactlyFiveOfEightJobs() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(runner: runner)
        let jobs = DownloadJob.fixtures(count: 8)

        await coordinator.enqueue(jobs)
        await runner.waitForStarted(count: 5)

        let startedIDs = await runner.startedIDs
        XCTAssertEqual(Set(startedIDs), Set(jobs.prefix(5).map(\.id)))
        await coordinator.shutdown()
    }

    func testExplicitLimitsStartOneFiveAndTenJobs() async {
        for limit in [1, 5, 10] {
            let runner = GatedRunner()
            let coordinator = DownloadCoordinator(limit: limit, runner: runner)
            let jobs = DownloadJob.fixtures(count: 12)

            await coordinator.enqueue(jobs)
            await runner.waitForStarted(count: limit)

            let startedIDs = await runner.startedIDs
            XCTAssertEqual(Set(startedIDs), Set(jobs.prefix(limit).map(\.id)), "limit \(limit)")
            await coordinator.shutdown()
        }
    }

    func testConcurrentStartsEmitFIFOCoordinatorEvents() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 10, runner: runner)
        let jobs = DownloadJob.fixtures(count: 12)
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
        }

        await coordinator.enqueue(jobs)
        await recorder.waitForStarted(count: 10)
        await coordinator.shutdown()
        _ = await observer.value

        let startedIDs = await recorder.events.compactMap { event -> UUID? in
            if case let .started(jobID) = event { return jobID }
            return nil
        }
        XCTAssertEqual(startedIDs, Array(jobs.prefix(10)).map(\.id))
    }

    func testLimitsClampToTheSupportedRange() async {
        let lowRunner = GatedRunner()
        let lowCoordinator = DownloadCoordinator(limit: 0, runner: lowRunner)
        await lowCoordinator.enqueue(DownloadJob.fixtures(count: 2))
        await lowRunner.waitForStarted(count: 1)
        let lowStarted = await lowRunner.startedIDs
        XCTAssertEqual(lowStarted.count, 1)
        await lowCoordinator.shutdown()

        let highRunner = GatedRunner()
        let highCoordinator = DownloadCoordinator(limit: 99, runner: highRunner)
        await highCoordinator.enqueue(DownloadJob.fixtures(count: 11))
        await highRunner.waitForStarted(count: 10)
        let highStarted = await highRunner.startedIDs
        XCTAssertEqual(highStarted.count, 10)
        await highCoordinator.shutdown()
    }

    func testRaisingLimitImmediatelyFillsNewSlots() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 4)

        await coordinator.enqueue(jobs)
        await runner.waitForStarted(count: 1)
        await coordinator.setLimit(3)
        await runner.waitForStarted(count: 3)

        let startedIDs = await runner.startedIDs
        XCTAssertEqual(Set(startedIDs), Set(jobs.prefix(3).map(\.id)))
        await coordinator.shutdown()
    }

    func testLoweringLimitPreservesActiveJobsAndDelaysReplacement() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 5, runner: runner)
        let jobs = DownloadJob.fixtures(count: 8)

        await coordinator.enqueue(jobs)
        await runner.waitForStarted(count: 5)
        await coordinator.setLimit(2)

        for job in jobs.prefix(3) {
            await runner.complete(job.id)
        }
        await runner.waitForStopped(count: 3)
        let startedBeforeReplacement = await runner.startedIDs
        XCTAssertEqual(startedBeforeReplacement.count, 5)

        await runner.complete(jobs[3].id)
        await runner.waitForStarted(count: 6)
        let startedAfterReplacement = await runner.startedIDs
        XCTAssertEqual(startedAfterReplacement.last, jobs[5].id)
        await coordinator.shutdown()
    }

    func testFIFOAndStartNowPromotionNeverExceedTheLimit() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)

        await coordinator.enqueue(jobs)
        await runner.waitForStarted(count: 1)
        await coordinator.startNow(jobs[2].id)

        let startedBeforeCompletion = await runner.startedIDs
        XCTAssertEqual(startedBeforeCompletion, [jobs[0].id])
        await runner.complete(jobs[0].id)
        await runner.waitForStarted(count: 2)
        let startedAfterCompletion = await runner.startedIDs
        XCTAssertEqual(startedAfterCompletion, [jobs[0].id, jobs[2].id])
        await coordinator.shutdown()
    }

    func testFailureStartsNextJobAndLeavesSiblingActive() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 2, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)

        await coordinator.enqueue(jobs)
        await runner.waitForStarted(count: 2)
        await runner.fail(jobs[0].id)
        await runner.waitForStarted(count: 3)

        let activeIDs = await runner.activeIDs
        XCTAssertEqual(activeIDs, Set([jobs[1].id, jobs[2].id]))
        await coordinator.shutdown()
    }

    func testDuplicateEnqueueAndControlCommandsAreIdempotent() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 2)

        await coordinator.enqueue([jobs[0], jobs[0], jobs[1]])
        await runner.waitForStarted(count: 1)
        await coordinator.pause(jobs[1].id)
        await coordinator.pause(jobs[1].id)
        await coordinator.resume(jobs[1].id)
        await coordinator.resume(jobs[1].id)
        await runner.complete(jobs[0].id)
        await runner.waitForStarted(count: 2)

        await coordinator.cancel(jobs[1].id)
        await coordinator.cancel(jobs[1].id)
        let pauseCalls = await runner.pauseCalls(for: jobs[1].id)
        let cancelCalls = await runner.cancelCalls(for: jobs[1].id)
        XCTAssertEqual(pauseCalls, 0)
        XCTAssertEqual(cancelCalls, 1)
        await coordinator.shutdown()
    }

    func testQueuedPauseAndCancelNeverLaunchTheJob() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)

        await coordinator.enqueue(jobs)
        await runner.waitForStarted(count: 1)
        await coordinator.pause(jobs[1].id)
        await coordinator.cancel(jobs[2].id)
        await runner.complete(jobs[0].id)
        await runner.waitForStopped(count: 1)

        let startedIDs = await runner.startedIDs
        XCTAssertEqual(startedIDs, [jobs[0].id])
        await coordinator.shutdown()
    }

    func testActivePauseAndCancelDelegateOnceAndStartAtMostOneReplacement() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)

        await coordinator.enqueue(jobs)
        await runner.waitForStarted(count: 1)
        async let firstPause: Void = coordinator.pause(jobs[0].id)
        async let secondPause: Void = coordinator.pause(jobs[0].id)
        _ = await (firstPause, secondPause)
        await runner.waitForStarted(count: 2)

        async let firstCancel: Void = coordinator.cancel(jobs[1].id)
        async let secondCancel: Void = coordinator.cancel(jobs[1].id)
        _ = await (firstCancel, secondCancel)
        await runner.waitForStarted(count: 3)

        let pauseCalls = await runner.pauseCalls(for: jobs[0].id)
        let cancelCalls = await runner.cancelCalls(for: jobs[1].id)
        let startedIDs = await runner.startedIDs
        XCTAssertEqual(pauseCalls, 1)
        XCTAssertEqual(cancelCalls, 1)
        XCTAssertEqual(startedIDs, jobs.map(\.id))
        await coordinator.shutdown()
    }

    func testResumeRequeuesPausedJobExactlyOnce() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 2)

        await coordinator.enqueue(jobs)
        await runner.waitForStarted(count: 1)
        await coordinator.pause(jobs[1].id)
        await coordinator.resume(jobs[1].id)
        await coordinator.resume(jobs[1].id)
        await runner.complete(jobs[0].id)
        await runner.waitForStarted(count: 2)

        let startedIDs = await runner.startedIDs
        XCTAssertEqual(startedIDs.filter { $0 == jobs[1].id }.count, 1)
        await coordinator.shutdown()
    }

    func testEventsRemainOrderedAndStopExactlyOnce() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let job = DownloadJob.fixture()
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
        }

        await coordinator.enqueue(job)
        await runner.waitForStarted(count: 1)
        await runner.emit(.progress(JobProgress(fraction: 0.5, downloadedBytes: 50, totalBytes: 100, bytesPerSecond: 10, etaSeconds: 5)), for: job.id)
        await runner.complete(job.id)
        await recorder.waitForStopped(job.id)
        await coordinator.shutdown()
        _ = await observer.value

        let events = await recorder.events
        XCTAssertEqual(events, [
            CoordinatorEvent.started(job.id),
            CoordinatorEvent.runnerEvent(job.id, .progress(JobProgress(fraction: 0.5, downloadedBytes: 50, totalBytes: 100, bytesPerSecond: 10, etaSeconds: 5))),
            CoordinatorEvent.runnerEvent(job.id, .completed),
            CoordinatorEvent.stopped(job.id, .completed)
        ])
    }

    func testShutdownUsesQuitForMergingWaitsForWorkersAndPreservesQueue() async {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 2, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
        }

        await coordinator.enqueue(jobs)
        await runner.waitForStarted(count: 2)
        await runner.emit(.phase(.merging), for: jobs[1].id)
        await recorder.wait(for: CoordinatorEvent.runnerEvent(jobs[1].id, .phase(.merging)))

        await coordinator.shutdown()
        _ = await observer.value

        let pauseCalls = await runner.pauseCalls(for: jobs[0].id)
        let quitCalls = await runner.quitCalls(for: jobs[1].id)
        let startedIDs = await runner.startedIDs
        let stoppedStatuses = await recorder.stoppedStatuses
        XCTAssertEqual(pauseCalls, 1)
        XCTAssertEqual(quitCalls, 1)
        XCTAssertEqual(startedIDs, [jobs[0].id, jobs[1].id])
        XCTAssertEqual(stoppedStatuses, [jobs[0].id: [.paused], jobs[1].id: [.paused]])
    }
}

private actor GatedRunner: JobRunning {
    private var continuations: [UUID: AsyncThrowingStream<DownloadEvent, Error>.Continuation] = [:]
    private var jobs: [UUID: DownloadJob] = [:]
    private var starts: [UUID] = []
    private var paused: [UUID: Int] = [:]
    private var cancelled: [UUID: Int] = [:]
    private var quit: [UUID: Int] = [:]

    nonisolated func events(for job: DownloadJob) -> AsyncThrowingStream<DownloadEvent, Error> {
        var continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<DownloadEvent, Error> { continuation = $0 }
        if let continuation {
            Task { await self.start(job: job, continuation: continuation) }
        }
        return stream
    }

    func pause(jobID: UUID) async {
        guard continuations[jobID] != nil, paused[jobID] == nil else { return }
        paused[jobID] = 1
        finish(jobID, error: nil)
    }

    func cancel(jobID: UUID) async {
        guard continuations[jobID] != nil, cancelled[jobID] == nil else { return }
        cancelled[jobID] = 1
        finish(jobID, error: nil)
    }

    func interruptForQuit(jobID: UUID) async {
        guard continuations[jobID] != nil, quit[jobID] == nil else { return }
        quit[jobID] = 1
        finish(jobID, error: nil)
    }

    var startedIDs: [UUID] { starts }
    var activeIDs: Set<UUID> { Set(continuations.keys) }

    func pauseCalls(for jobID: UUID) -> Int { paused[jobID, default: 0] }
    func cancelCalls(for jobID: UUID) -> Int { cancelled[jobID, default: 0] }
    func quitCalls(for jobID: UUID) -> Int { quit[jobID, default: 0] }

    func waitForStarted(count: Int) async {
        while starts.count < count {
            await Task.yield()
        }
    }

    func waitForStopped(count: Int) async {
        while starts.count - continuations.count < count {
            await Task.yield()
        }
    }

    func emit(_ event: DownloadEvent, for jobID: UUID) {
        continuations[jobID]?.yield(event)
    }

    func complete(_ jobID: UUID) {
        continuations[jobID]?.yield(.completed)
        finish(jobID, error: nil)
    }

    func fail(_ jobID: UUID) {
        finish(jobID, error: DownloadFailure(category: .unknown, technicalDetail: "forced failure"))
    }

    private func start(job: DownloadJob, continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) {
        guard continuations[job.id] == nil else {
            continuation.finish(throwing: DownloadFailure(category: .unknown, technicalDetail: "duplicate fake run"))
            return
        }
        jobs[job.id] = job
        continuations[job.id] = continuation
        starts.append(job.id)
    }

    private func finish(_ jobID: UUID, error: Error?) {
        guard let continuation = continuations.removeValue(forKey: jobID) else { return }
        jobs[jobID] = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

private actor CoordinatorEventRecorder {
    private var recorded: [CoordinatorEvent] = []

    var events: [CoordinatorEvent] { recorded }

    var stoppedStatuses: [UUID: [DownloadStatus]] {
        var statuses: [UUID: [DownloadStatus]] = [:]
        for event in recorded {
            if case let .stopped(jobID, status) = event {
                statuses[jobID, default: []].append(status)
            }
        }
        return statuses
    }

    func record(_ event: CoordinatorEvent) {
        recorded.append(event)
    }

    func waitForStopped(_ jobID: UUID) async {
        while !recorded.contains(where: { event in
            if case let .stopped(id, _) = event { return id == jobID }
            return false
        }) {
            await Task.yield()
        }
    }

    func waitForStarted(count: Int) async {
        while recorded.reduce(into: 0, { count, event in
            if case .started = event { count += 1 }
        }) < count {
            await Task.yield()
        }
    }

    func wait(for expected: CoordinatorEvent) async {
        while !recorded.contains(expected) {
            await Task.yield()
        }
    }
}
