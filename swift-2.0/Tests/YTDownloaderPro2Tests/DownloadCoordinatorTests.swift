import Foundation
import XCTest
@testable import YTDownloaderPro2

final class DownloadCoordinatorTests: XCTestCase {
    func testDefaultLimitStartsExactlyFiveOfEightJobs() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(runner: runner)
        let jobs = DownloadJob.fixtures(count: 8)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 5)

        let startedIDs = await runner.startedIDs
        XCTAssertEqual(Set(startedIDs), Set(jobs.prefix(5).map(\.id)))
        await coordinator.shutdown()
    }

    func testExplicitLimitsStartOneFiveAndTenJobs() async throws {
        for limit in [1, 5, 10] {
            let runner = GatedRunner()
            let coordinator = DownloadCoordinator(limit: limit, runner: runner)
            let jobs = DownloadJob.fixtures(count: 12)

            await coordinator.enqueue(jobs)
            try await runner.waitForStarted(count: limit)

            let startedIDs = await runner.startedIDs
            XCTAssertEqual(Set(startedIDs), Set(jobs.prefix(limit).map(\.id)), "limit \(limit)")
            await coordinator.shutdown()
        }
    }

    func testConcurrentStartsEmitFIFOCoordinatorEvents() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 10, runner: runner)
        let jobs = DownloadJob.fixtures(count: 12)
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
            await recorder.markStreamFinished()
        }

        await coordinator.enqueue(jobs)
        try await recorder.waitForStarted(count: 10)
        await coordinator.shutdown()
        try await recorder.waitForStreamFinished()
        observer.cancel()

        let startedIDs = await recorder.events.compactMap { event -> UUID? in
            if case let .started(jobID) = event { return jobID }
            return nil
        }
        XCTAssertEqual(startedIDs, Array(jobs.prefix(10)).map(\.id))
    }

    func testLimitsClampToTheSupportedRange() async throws {
        let lowRunner = GatedRunner()
        let lowCoordinator = DownloadCoordinator(limit: 0, runner: lowRunner)
        await lowCoordinator.enqueue(DownloadJob.fixtures(count: 2))
        try await lowRunner.waitForStarted(count: 1)
        let lowStarted = await lowRunner.startedIDs
        XCTAssertEqual(lowStarted.count, 1)
        await lowCoordinator.shutdown()

        let highRunner = GatedRunner()
        let highCoordinator = DownloadCoordinator(limit: 99, runner: highRunner)
        await highCoordinator.enqueue(DownloadJob.fixtures(count: 11))
        try await highRunner.waitForStarted(count: 10)
        let highStarted = await highRunner.startedIDs
        XCTAssertEqual(highStarted.count, 10)
        await highCoordinator.shutdown()
    }

    func testRaisingLimitImmediatelyFillsNewSlots() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 4)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 1)
        await coordinator.setLimit(3)
        try await runner.waitForStarted(count: 3)

        let startedIDs = await runner.startedIDs
        XCTAssertEqual(Set(startedIDs), Set(jobs.prefix(3).map(\.id)))
        await coordinator.shutdown()
    }

    func testLoweringLimitPreservesActiveJobsAndDelaysReplacement() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 5, runner: runner)
        let jobs = DownloadJob.fixtures(count: 8)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 5)
        await coordinator.setLimit(2)

        for job in jobs.prefix(3) {
            await runner.complete(job.id)
        }
        try await runner.waitForStopped(count: 3)
        let startedBeforeReplacement = await runner.startedIDs
        XCTAssertEqual(startedBeforeReplacement.count, 5)

        await runner.complete(jobs[3].id)
        try await runner.waitForStarted(count: 6)
        let startedAfterReplacement = await runner.startedIDs
        XCTAssertEqual(startedAfterReplacement.last, jobs[5].id)
        await coordinator.shutdown()
    }

    func testFIFOAndStartNowPromotionNeverExceedTheLimit() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 1)
        await coordinator.startNow(jobs[2].id)

        let startedBeforeCompletion = await runner.startedIDs
        XCTAssertEqual(startedBeforeCompletion, [jobs[0].id])
        await runner.complete(jobs[0].id)
        try await runner.waitForStarted(count: 2)
        let startedAfterCompletion = await runner.startedIDs
        XCTAssertEqual(startedAfterCompletion, [jobs[0].id, jobs[2].id])
        await coordinator.shutdown()
    }

    func testFailureStartsNextJobAndLeavesSiblingActive() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 2, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 2)
        await runner.fail(jobs[0].id)
        try await runner.waitForStarted(count: 3)

        let activeIDs = await runner.activeIDs
        XCTAssertEqual(activeIDs, Set([jobs[1].id, jobs[2].id]))
        await coordinator.shutdown()
    }

    func testFailureEventPreservesTypedSanitizedDownloadFailureBeforeStopped() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let job = DownloadJob.fixture()
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
        }
        let failure = DownloadFailure(
            category: .diskFull,
            technicalDetail: "authorization=secret no space",
            toolExitCode: 28
        )

        await coordinator.enqueue(job)
        try await runner.waitForStarted(count: 1)
        await runner.fail(job.id, with: failure)
        try await recorder.waitForStopped(job.id)
        await coordinator.shutdown()
        observer.cancel()

        let expected = DownloadFailure(
            category: .diskFull,
            technicalDetail: "authorization=[REDACTED] no space",
            toolExitCode: 28,
            occurredAt: failure.occurredAt
        )
        let events = await recorder.events
        XCTAssertEqual(events, [
            .started(job.id),
            .failure(job.id, expected),
            .stopped(job.id, .failed)
        ])
    }

    func testDuplicateEnqueueAndControlCommandsAreIdempotent() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 2)

        await coordinator.enqueue([jobs[0], jobs[0], jobs[1]])
        try await runner.waitForStarted(count: 1)
        await coordinator.pause(jobs[1].id)
        await coordinator.pause(jobs[1].id)
        await coordinator.resume(jobs[1].id)
        await coordinator.resume(jobs[1].id)
        await runner.complete(jobs[0].id)
        try await runner.waitForStarted(count: 2)

        await coordinator.cancel(jobs[1].id)
        await coordinator.cancel(jobs[1].id)
        let pauseCalls = await runner.pauseCalls(for: jobs[1].id)
        let cancelCalls = await runner.cancelCalls(for: jobs[1].id)
        XCTAssertEqual(pauseCalls, 0)
        XCTAssertEqual(cancelCalls, 1)
        await coordinator.shutdown()
    }

    func testQueuedPauseAndCancelNeverLaunchTheJob() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 1)
        await coordinator.pause(jobs[1].id)
        await coordinator.cancel(jobs[2].id)
        await runner.complete(jobs[0].id)
        try await runner.waitForStopped(count: 1)

        let startedIDs = await runner.startedIDs
        XCTAssertEqual(startedIDs, [jobs[0].id])
        await coordinator.shutdown()
    }

    func testCancellingPausedJobDelegatesOwnedCleanupWithoutRestartingIt() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 2)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 1)
        let pauseAccepted = await coordinator.pause(jobs[1].id)
        XCTAssertTrue(pauseAccepted)
        await coordinator.cancel(jobs[1].id)

        let cleanupCalls = await runner.cancelCalls(for: jobs[1].id)
        let startedIDs = await runner.startedIDs
        XCTAssertEqual(cleanupCalls, 1)
        XCTAssertEqual(startedIDs, [jobs[0].id])
        await coordinator.shutdown()
    }

    func testResumeIsRejectedWhilePausedCancellationCleanupIsSuspended() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 2)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 1)
        let pauseAccepted = await coordinator.pause(jobs[1].id)
        XCTAssertTrue(pauseAccepted)
        await runner.blockCleanup(jobID: jobs[1].id)

        let cancellation = Task { await coordinator.cancel(jobs[1].id) }
        try await runner.waitForCleanupRequests(jobID: jobs[1].id, count: 1)
        await coordinator.resume(jobs[1].id)
        await runner.complete(jobs[0].id)
        try await Task.sleep(for: .milliseconds(20))

        let startedDuringCleanup = await runner.startedIDs
        XCTAssertEqual(startedDuringCleanup, [jobs[0].id])

        await runner.releaseCleanup(jobID: jobs[1].id)
        await cancellation.value
        await coordinator.shutdown()
    }

    func testDuplicatePausedCancellationJoinsOneSuspendedCleanup() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 2)
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
        }

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 1)
        let pauseAccepted = await coordinator.pause(jobs[1].id)
        XCTAssertTrue(pauseAccepted)
        await runner.blockCleanup(jobID: jobs[1].id)

        let first = Task { await coordinator.cancel(jobs[1].id) }
        try await runner.waitForCleanupRequests(jobID: jobs[1].id, count: 1)
        let second = Task { await coordinator.cancel(jobs[1].id) }
        try await Task.sleep(for: .milliseconds(20))

        let cleanupRequests = await runner.cleanupRequests(for: jobs[1].id)
        XCTAssertEqual(cleanupRequests, 1)

        await runner.releaseCleanup(jobID: jobs[1].id)
        await first.value
        await second.value
        try await recorder.waitForStopped(jobs[1].id)
        let stoppedStatuses = await recorder.stoppedStatuses
        XCTAssertEqual(stoppedStatuses[jobs[1].id], [.paused, .cancelled])

        await coordinator.shutdown()
        observer.cancel()
    }

    func testActivePauseAndCancelDelegateOnceAndStartAtMostOneReplacement() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 1)
        async let firstPause = coordinator.pause(jobs[0].id)
        async let secondPause = coordinator.pause(jobs[0].id)
        let pauseResults = await (firstPause, secondPause)
        try await runner.waitForStarted(count: 2)

        async let firstCancel: Void = coordinator.cancel(jobs[1].id)
        async let secondCancel: Void = coordinator.cancel(jobs[1].id)
        _ = await (firstCancel, secondCancel)
        try await runner.waitForStarted(count: 3)

        let pauseCalls = await runner.pauseCalls(for: jobs[0].id)
        let cancelCalls = await runner.cancelCalls(for: jobs[1].id)
        let startedIDs = await runner.startedIDs
        XCTAssertEqual([pauseResults.0, pauseResults.1], [true, true])
        XCTAssertEqual(pauseCalls, 1)
        XCTAssertEqual(cancelCalls, 1)
        XCTAssertEqual(startedIDs, jobs.map(\.id))
        await coordinator.shutdown()
    }

    func testActivePauseUsesOrdinaryPauseInsteadOfQuitInterruption() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let job = DownloadJob.fixture()

        await coordinator.enqueue(job)
        try await runner.waitForStarted(count: 1)
        let accepted = await coordinator.pause(job.id)

        let pauseCalls = await runner.pauseCalls(for: job.id)
        let quitMethodCalls = await runner.quitMethodCalls(for: job.id)
        XCTAssertTrue(accepted)
        XCTAssertEqual(pauseCalls, 1)
        XCTAssertEqual(quitMethodCalls, 0)
        await coordinator.shutdown()
    }

    func testResumeRequeuesPausedJobExactlyOnce() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let jobs = DownloadJob.fixtures(count: 2)

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 1)
        await coordinator.pause(jobs[1].id)
        await coordinator.resume(jobs[1].id)
        await coordinator.resume(jobs[1].id)
        await runner.complete(jobs[0].id)
        try await runner.waitForStarted(count: 2)

        let startedIDs = await runner.startedIDs
        XCTAssertEqual(startedIDs.filter { $0 == jobs[1].id }.count, 1)
        await coordinator.shutdown()
    }

    func testEventsRemainOrderedAndStopExactlyOnce() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let job = DownloadJob.fixture()
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
            await recorder.markStreamFinished()
        }

        await coordinator.enqueue(job)
        try await runner.waitForStarted(count: 1)
        await runner.emit(.progress(JobProgress(fraction: 0.5, downloadedBytes: 50, totalBytes: 100, bytesPerSecond: 10, etaSeconds: 5)), for: job.id)
        await runner.complete(job.id)
        try await recorder.waitForStopped(job.id)
        await coordinator.shutdown()
        try await recorder.waitForStreamFinished()
        observer.cancel()

        let events = await recorder.events
        XCTAssertEqual(events, [
            CoordinatorEvent.started(job.id),
            CoordinatorEvent.runnerEvent(job.id, .progress(JobProgress(fraction: 0.5, downloadedBytes: 50, totalBytes: 100, bytesPerSecond: 10, etaSeconds: 5))),
            CoordinatorEvent.runnerEvent(job.id, .completed),
            CoordinatorEvent.stopped(job.id, .completed)
        ])
    }

    func testShutdownUsesQuitForMergingWaitsForWorkersAndPreservesQueue() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 2, runner: runner)
        let jobs = DownloadJob.fixtures(count: 3)
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
            await recorder.markStreamFinished()
        }

        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 2)
        await runner.emit(.phase(.merging), for: jobs[1].id)
        try await recorder.wait(for: CoordinatorEvent.runnerEvent(jobs[1].id, .phase(.merging)))

        await coordinator.shutdown()
        try await recorder.waitForStreamFinished()
        observer.cancel()

        let pauseCalls = await runner.pauseCalls(for: jobs[0].id)
        let quitCalls = await runner.quitCalls(for: jobs[1].id)
        let startedIDs = await runner.startedIDs
        let stoppedStatuses = await recorder.stoppedStatuses
        XCTAssertEqual(pauseCalls, 1)
        XCTAssertEqual(quitCalls, 1)
        XCTAssertEqual(Set(startedIDs), Set([jobs[0].id, jobs[1].id]))
        XCTAssertEqual(stoppedStatuses, [jobs[0].id: [.paused], jobs[1].id: [.paused]])
    }

    func testShutdownJoinsBlockedPauseCancelAndRepeatedShutdownCallers() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 2, runner: runner)
        let jobs = DownloadJob.fixtures(count: 2)
        let recorder = CoordinatorEventRecorder()
        let firstShutdown = CompletionProbe()
        let secondShutdown = CompletionProbe()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
            await recorder.markStreamFinished()
        }

        await runner.blockPause(jobID: jobs[0].id)
        await runner.blockCancel(jobID: jobs[1].id)
        await coordinator.enqueue(jobs)
        try await runner.waitForStarted(count: 2)

        let pauseTask = Task { await coordinator.pause(jobs[0].id) }
        let cancelTask = Task { await coordinator.cancel(jobs[1].id) }
        try await runner.waitForPauseRequests(jobID: jobs[0].id, count: 1)
        try await runner.waitForCancelRequests(jobID: jobs[1].id, count: 1)

        let firstShutdownTask = Task {
            await firstShutdown.markStarted()
            await coordinator.shutdown()
            await firstShutdown.markCompleted()
        }
        let secondShutdownTask = Task {
            await secondShutdown.markStarted()
            await coordinator.shutdown()
            await secondShutdown.markCompleted()
        }
        try await firstShutdown.waitForStarted()
        try await secondShutdown.waitForStarted()
        try await Task.sleep(for: .milliseconds(20))
        let firstCompletedEarly = await firstShutdown.isCompleted
        let secondCompletedEarly = await secondShutdown.isCompleted

        await runner.releasePause(jobID: jobs[0].id)
        try await Task.sleep(for: .milliseconds(20))
        let firstCompletedBeforeCancelCleanup = await firstShutdown.isCompleted
        let secondCompletedBeforeCancelCleanup = await secondShutdown.isCompleted
        let completedBeforeCancelCleanup = firstCompletedBeforeCancelCleanup || secondCompletedBeforeCancelCleanup
        await runner.releaseCancel(jobID: jobs[1].id)

        try await firstShutdown.waitForCompleted()
        try await secondShutdown.waitForCompleted()
        try await recorder.waitForStreamFinished()
        let stoppedStatuses = await recorder.stoppedStatuses

        XCTAssertFalse(firstCompletedEarly)
        XCTAssertFalse(secondCompletedEarly)
        XCTAssertFalse(completedBeforeCancelCleanup)
        XCTAssertEqual(stoppedStatuses, [jobs[0].id: [.paused], jobs[1].id: [.cancelled]])

        pauseTask.cancel()
        cancelTask.cancel()
        firstShutdownTask.cancel()
        secondShutdownTask.cancel()
        observer.cancel()
    }

    func testBufferedMergePhaseRejectsPauseAndFinishesCompletedExactlyOnce() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let job = DownloadJob.fixture()
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
            await recorder.markStreamFinished()
        }

        await coordinator.enqueue(job)
        try await runner.waitForStarted(count: 1)
        await runner.emit(.phase(.downloading), for: job.id)
        try await recorder.wait(for: .runnerEvent(job.id, .phase(.downloading)))
        await runner.queuePhaseBeforeDelivery(.merging, for: job.id)

        let pauseTask = Task { await coordinator.pause(job.id) }
        try await runner.waitForControlRequests(jobID: job.id, count: 1)
        let pauseAccepted = await pauseTask.value
        XCTAssertFalse(pauseAccepted)
        await runner.completeAfterDeliveringPendingEvents(jobID: job.id)
        try await recorder.waitForStopped(job.id)

        let acceptedPauseCalls = await runner.pauseCalls(for: job.id)
        let events = await recorder.events
        let stoppedStatuses = await recorder.stoppedStatuses
        XCTAssertEqual(acceptedPauseCalls, 0)
        XCTAssertTrue(events.contains(.runnerEvent(job.id, .phase(.merging))))
        XCTAssertEqual(stoppedStatuses[job.id], [.completed])

        await coordinator.shutdown()
        try await recorder.waitForStreamFinished()
        observer.cancel()
    }

    func testBufferedPostprocessingPhaseRejectsPauseAndFinishesCompletedExactlyOnce() async throws {
        let runner = GatedRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let job = DownloadJob.fixture()
        let recorder = CoordinatorEventRecorder()
        let observer = Task {
            for await event in coordinator.events {
                await recorder.record(event)
            }
            await recorder.markStreamFinished()
        }

        await coordinator.enqueue(job)
        try await runner.waitForStarted(count: 1)
        await runner.emit(.phase(.downloading), for: job.id)
        try await recorder.wait(for: .runnerEvent(job.id, .phase(.downloading)))
        await runner.queuePhaseBeforeDelivery(.postprocessing, for: job.id)

        let pauseTask = Task { await coordinator.pause(job.id) }
        try await runner.waitForControlRequests(jobID: job.id, count: 1)
        let pauseAccepted = await pauseTask.value
        XCTAssertFalse(pauseAccepted)
        await runner.completeAfterDeliveringPendingEvents(jobID: job.id)
        try await recorder.waitForStopped(job.id)

        let acceptedPauseCalls = await runner.pauseCalls(for: job.id)
        let events = await recorder.events
        let stoppedStatuses = await recorder.stoppedStatuses
        XCTAssertEqual(acceptedPauseCalls, 0)
        XCTAssertTrue(events.contains(.runnerEvent(job.id, .phase(.postprocessing))))
        XCTAssertEqual(stoppedStatuses[job.id], [.completed])

        await coordinator.shutdown()
        try await recorder.waitForStreamFinished()
        observer.cancel()
    }
}

private actor GatedRunner: JobRunning {
    private var continuations: [UUID: AsyncThrowingStream<DownloadEvent, Error>.Continuation] = [:]
    private var jobs: [UUID: DownloadJob] = [:]
    private var starts: [UUID] = []
    private var paused: [UUID: Int] = [:]
    private var cancelled: [UUID: Int] = [:]
    private var quit: [UUID: Int] = [:]
    private var quitMethods: [UUID: Int] = [:]
    private var pauseRequests: [UUID: Int] = [:]
    private var cancelRequests: [UUID: Int] = [:]
    private var controlRequests: [UUID: Int] = [:]
    private var phases: [UUID: DownloadPhase] = [:]
    private var pendingEvents: [UUID: [DownloadEvent]] = [:]
    private var blockedPauseIDs: Set<UUID> = []
    private var blockedCancelIDs: Set<UUID> = []
    private var blockedCleanupIDs: Set<UUID> = []
    private var pauseWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var cleanupWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var cleanupRequestCounts: [UUID: Int] = [:]

    nonisolated func events(for job: DownloadJob) -> AsyncThrowingStream<DownloadEvent, Error> {
        var continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<DownloadEvent, Error> { continuation = $0 }
        if let continuation {
            Task { await self.start(job: job, continuation: continuation) }
        }
        return stream
    }

    func pause(jobID: UUID) async -> Bool {
        pauseRequests[jobID, default: 0] += 1
        controlRequests[jobID, default: 0] += 1
        if blockedPauseIDs.contains(jobID) {
            await withCheckedContinuation { continuation in
                pauseWaiters[jobID, default: []].append(continuation)
            }
        }
        guard continuations[jobID] != nil, paused[jobID] == nil,
              phases[jobID] != .merging, phases[jobID] != .postprocessing else { return false }
        paused[jobID] = 1
        finish(jobID, error: nil)
        return true
    }

    func cancel(jobID: UUID) async {
        cancelRequests[jobID, default: 0] += 1
        controlRequests[jobID, default: 0] += 1
        if blockedCancelIDs.contains(jobID) {
            await withCheckedContinuation { continuation in
                cancelWaiters[jobID, default: []].append(continuation)
            }
        }
        guard continuations[jobID] != nil, cancelled[jobID] == nil else { return }
        cancelled[jobID] = 1
        finish(jobID, error: nil)
    }

    func cleanupCancelledJob(_ job: DownloadJob) async {
        cleanupRequestCounts[job.id, default: 0] += 1
        if blockedCleanupIDs.contains(job.id) {
            await withCheckedContinuation { continuation in
                cleanupWaiters[job.id, default: []].append(continuation)
            }
        }
        cancelRequests[job.id, default: 0] += 1
        cancelled[job.id, default: 0] += 1
    }

    func interruptForQuit(jobID: UUID) async {
        quitMethods[jobID, default: 0] += 1
        guard continuations[jobID] != nil else { return }
        controlRequests[jobID, default: 0] += 1
        if blockedPauseIDs.contains(jobID) {
            pauseRequests[jobID, default: 0] += 1
            await withCheckedContinuation { continuation in
                pauseWaiters[jobID, default: []].append(continuation)
            }
        }
        guard continuations[jobID] != nil else { return }
        if phases[jobID] == .merging || phases[jobID] == .postprocessing {
            quit[jobID, default: 0] += 1
        } else {
            paused[jobID, default: 0] += 1
        }
        deliverPendingEvents(for: jobID)
        finish(jobID, error: nil)
    }

    var startedIDs: [UUID] { starts }
    var activeIDs: Set<UUID> { Set(continuations.keys) }

    func pauseCalls(for jobID: UUID) -> Int { paused[jobID, default: 0] }
    func cancelCalls(for jobID: UUID) -> Int { cancelled[jobID, default: 0] }
    func quitCalls(for jobID: UUID) -> Int { quit[jobID, default: 0] }
    func quitMethodCalls(for jobID: UUID) -> Int { quitMethods[jobID, default: 0] }

    func blockPause(jobID: UUID) {
        blockedPauseIDs.insert(jobID)
    }

    func blockCancel(jobID: UUID) {
        blockedCancelIDs.insert(jobID)
    }

    func blockCleanup(jobID: UUID) {
        blockedCleanupIDs.insert(jobID)
    }

    func releasePause(jobID: UUID) {
        blockedPauseIDs.remove(jobID)
        let waiters = pauseWaiters.removeValue(forKey: jobID) ?? []
        waiters.forEach { $0.resume() }
    }

    func releaseCancel(jobID: UUID) {
        blockedCancelIDs.remove(jobID)
        let waiters = cancelWaiters.removeValue(forKey: jobID) ?? []
        waiters.forEach { $0.resume() }
    }

    func releaseCleanup(jobID: UUID) {
        blockedCleanupIDs.remove(jobID)
        let waiters = cleanupWaiters.removeValue(forKey: jobID) ?? []
        waiters.forEach { $0.resume() }
    }

    func waitForStarted(count: Int) async throws {
        try await waitUntil("runner to start \(count) job(s)") { starts.count >= count }
    }

    func waitForStopped(count: Int) async throws {
        try await waitUntil("runner to stop \(count) job(s)") { starts.count - continuations.count >= count }
    }

    func waitForPauseRequests(jobID: UUID, count: Int) async throws {
        try await waitUntil("pause request \(count) for \(jobID)") { pauseRequests[jobID, default: 0] >= count }
    }

    func waitForCancelRequests(jobID: UUID, count: Int) async throws {
        try await waitUntil("cancel request \(count) for \(jobID)") { cancelRequests[jobID, default: 0] >= count }
    }

    func waitForCleanupRequests(jobID: UUID, count: Int) async throws {
        try await waitUntil("cleanup request \(count) for \(jobID)") {
            cleanupRequestCounts[jobID, default: 0] >= count
        }
    }

    func cleanupRequests(for jobID: UUID) -> Int {
        cleanupRequestCounts[jobID, default: 0]
    }

    func waitForControlRequests(jobID: UUID, count: Int) async throws {
        try await waitUntil("control request \(count) for \(jobID)") { controlRequests[jobID, default: 0] >= count }
    }

    func waitForQuitCalls(jobID: UUID, count: Int, timeout: Duration = .seconds(2)) async throws {
        try await waitUntil("quit interruption \(count) for \(jobID)", timeout: timeout) { quit[jobID, default: 0] >= count }
    }

    func emit(_ event: DownloadEvent, for jobID: UUID) {
        if case let .phase(phase) = event {
            phases[jobID] = phase
        }
        continuations[jobID]?.yield(event)
    }

    func queuePhaseBeforeDelivery(_ phase: DownloadPhase, for jobID: UUID) {
        phases[jobID] = phase
        pendingEvents[jobID, default: []].append(.phase(phase))
    }

    func forceFinish(jobID: UUID) {
        deliverPendingEvents(for: jobID)
        finish(jobID, error: nil)
    }

    func completeAfterDeliveringPendingEvents(jobID: UUID) {
        deliverPendingEvents(for: jobID)
        continuations[jobID]?.yield(.completed)
        finish(jobID, error: nil)
    }

    func complete(_ jobID: UUID) {
        continuations[jobID]?.yield(.completed)
        finish(jobID, error: nil)
    }

    func fail(_ jobID: UUID) {
        finish(jobID, error: DownloadFailure(category: .unknown, technicalDetail: "forced failure"))
    }

    func fail(_ jobID: UUID, with failure: DownloadFailure) {
        finish(jobID, error: failure)
    }

    private func start(job: DownloadJob, continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) {
        guard continuations[job.id] == nil else {
            continuation.finish(throwing: DownloadFailure(category: .unknown, technicalDetail: "duplicate fake run"))
            return
        }
        jobs[job.id] = job
        continuations[job.id] = continuation
        phases[job.id] = .downloading
        starts.append(job.id)
    }

    private func finish(_ jobID: UUID, error: Error?) {
        guard let continuation = continuations.removeValue(forKey: jobID) else { return }
        jobs[jobID] = nil
        phases[jobID] = nil
        pendingEvents[jobID] = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func deliverPendingEvents(for jobID: UUID) {
        let events = pendingEvents.removeValue(forKey: jobID) ?? []
        for event in events {
            continuations[jobID]?.yield(event)
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw CoordinatorTestWaitError.timedOut(description)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor CoordinatorEventRecorder {
    private var recorded: [CoordinatorEvent] = []
    private var streamFinished = false

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

    func markStreamFinished() {
        streamFinished = true
    }

    func waitForStopped(_ jobID: UUID) async throws {
        try await waitUntil("stopped event for \(jobID)") {
            recorded.contains(where: { event in
                if case let .stopped(id, _) = event { return id == jobID }
                return false
            })
        }
    }

    func waitForStarted(count: Int) async throws {
        try await waitUntil("\(count) coordinator started event(s)") {
            recorded.reduce(into: 0, { count, event in
                if case .started = event { count += 1 }
            }) >= count
        }
    }

    func wait(for expected: CoordinatorEvent) async throws {
        try await waitUntil("coordinator event \(expected)") {
            recorded.contains(expected)
        }
    }

    func waitForStreamFinished() async throws {
        try await waitUntil("coordinator event stream to finish") { streamFinished }
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else {
                throw CoordinatorTestWaitError.timedOut(description)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor CompletionProbe {
    private var started = false
    private var completed = false

    var isCompleted: Bool { completed }

    func markStarted() {
        started = true
    }

    func markCompleted() {
        completed = true
    }

    func waitForStarted() async throws {
        try await waitUntil("operation to start") { started }
    }

    func waitForCompleted() async throws {
        try await waitUntil("operation to complete") { completed }
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else {
                throw CoordinatorTestWaitError.timedOut(description)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private enum CoordinatorTestWaitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case let .timedOut(description):
            "Timed out waiting for \(description)."
        }
    }
}
