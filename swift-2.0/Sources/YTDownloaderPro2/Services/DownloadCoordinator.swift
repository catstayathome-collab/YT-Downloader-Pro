import Foundation

enum CoordinatorEvent: Equatable, Sendable {
    case started(UUID)
    case runnerEvent(UUID, DownloadEvent)
    case failure(UUID, DownloadFailure)
    case stopped(UUID, DownloadStatus)
}

actor DownloadCoordinator {
    private enum RequestedStop: Equatable {
        case none
        case pause
        case cancel
        case shutdown
    }

    /// Keeps one runner pause decision joinable without treating it as accepted early.
    private struct PendingPause {
        let generation: UUID
        let task: Task<Bool, Never>
    }

    private struct PendingPausedCancellation {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private struct ActiveJob {
        let token: UUID
        var requestedStop: RequestedStop
        var pendingPause: PendingPause?
        var controlTask: Task<Void, Never>?
        let task: Task<Void, Never>
    }

    nonisolated let events: AsyncStream<CoordinatorEvent>

    private let runner: any JobRunning
    private let continuation: AsyncStream<CoordinatorEvent>.Continuation
    private var jobs: [UUID: DownloadJob] = [:]
    private var queuedIDs: [UUID] = []
    private var active: [UUID: ActiveJob] = [:]
    private var pendingPausedCancellations: [UUID: PendingPausedCancellation] = [:]
    private var limit: Int
    private var isShuttingDown = false
    private var didFinishEvents = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 5, runner: any JobRunning) {
        self.runner = runner
        self.limit = Self.clampedLimit(limit)

        var streamContinuation: AsyncStream<CoordinatorEvent>.Continuation?
        events = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation!
    }

    deinit {
        for worker in active.values {
            worker.pendingPause?.task.cancel()
            worker.controlTask?.cancel()
            worker.task.cancel()
        }
        for cancellation in pendingPausedCancellations.values {
            cancellation.task.cancel()
        }
        if !didFinishEvents {
            continuation.finish()
        }
    }

    func enqueue(_ job: DownloadJob) {
        enqueue([job])
    }

    func enqueue(_ newJobs: [DownloadJob]) {
        guard !isShuttingDown else { return }

        for job in newJobs where job.status == .queued {
            let existingStatus = jobs[job.id]?.status
            guard (existingStatus == nil || existingStatus?.isTerminal == true),
                  active[job.id] == nil,
                  !queuedIDs.contains(job.id) else { continue }
            jobs[job.id] = job
            queuedIDs.append(job.id)
        }
        startAvailableJobs()
    }

    func setLimit(_ value: Int) {
        limit = Self.clampedLimit(value)
        startAvailableJobs()
    }

    func startNow(_ jobID: UUID) {
        guard !isShuttingDown, let index = queuedIDs.firstIndex(of: jobID) else { return }
        queuedIDs.remove(at: index)
        queuedIDs.insert(jobID, at: 0)
        startAvailableJobs()
    }

    @discardableResult
    func pause(_ jobID: UUID) async -> Bool {
        guard !isShuttingDown else { return false }

        if removeQueued(jobID) {
            setStatus(.paused, for: jobID)
            continuation.yield(.stopped(jobID, .paused))
            return true
        }

        guard let worker = active[jobID], worker.requestedStop == .none, worker.controlTask == nil else {
            return active[jobID]?.requestedStop == .pause
        }
        let pendingPause: PendingPause
        if let existing = worker.pendingPause {
            pendingPause = existing
        } else {
            let runner = self.runner
            let request = PendingPause(
                generation: UUID(),
                task: Task { await runner.pause(jobID: jobID) }
            )
            active[jobID]?.pendingPause = request
            pendingPause = request
        }

        let accepted = await settlePause(
            jobID: jobID,
            workerToken: worker.token,
            generation: pendingPause.generation,
            task: pendingPause.task
        )
        if accepted {
            await worker.task.value
        }
        return accepted
    }

    func resume(_ jobID: UUID) {
        guard !isShuttingDown, pendingPausedCancellations[jobID] == nil,
              var job = jobs[jobID], job.status == .paused,
              !queuedIDs.contains(jobID), active[jobID] == nil else {
            return
        }
        job.status = .queued
        job.updatedAt = .now
        jobs[jobID] = job
        queuedIDs.append(jobID)
        startAvailableJobs()
    }

    func cancel(_ jobID: UUID) async {
        guard !isShuttingDown else { return }

        if let pending = pendingPausedCancellations[jobID] {
            await pending.task.value
            return
        }

        if removeQueued(jobID) {
            setStatus(.cancelled, for: jobID)
            continuation.yield(.stopped(jobID, .cancelled))
            return
        }

        if let job = jobs[jobID], job.status == .paused {
            let generation = UUID()
            let runner = self.runner
            let task = Task { [weak self, runner, job] in
                await runner.cleanupCancelledJob(job)
                await self?.finishPausedCancellation(jobID: job.id, generation: generation)
            }
            pendingPausedCancellations[jobID] = PendingPausedCancellation(
                generation: generation,
                task: task
            )
            await task.value
            return
        }

        guard let worker = active[jobID], worker.requestedStop == .none, worker.pendingPause == nil else { return }
        active[jobID]?.requestedStop = .cancel
        let runner = self.runner
        let controlTask = Task { await runner.cancel(jobID: jobID) }
        active[jobID]?.controlTask = controlTask
        await controlTask.value
        await worker.task.value
    }

    func cancelRestoredPaused(_ job: DownloadJob) async {
        guard !isShuttingDown, job.status == .paused else { return }
        if jobs[job.id] == nil, active[job.id] == nil, !queuedIDs.contains(job.id) {
            jobs[job.id] = job
        }
        await cancel(job.id)
    }

    /// Releases resumable artifacts before a terminal record leaves persistent history.
    func cleanupDiscardedRecord(_ job: DownloadJob) async -> Bool {
        guard !isShuttingDown, job.status.isTerminal,
              active[job.id] == nil,
              pendingPausedCancellations[job.id] == nil,
              !queuedIDs.contains(job.id) else { return false }

        if job.status != .completed, !(await runner.cleanupCancelledJob(job)) {
            return false
        }
        jobs[job.id] = nil
        return true
    }

    func shutdown() async {
        if didFinishEvents {
            return
        }
        if isShuttingDown {
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        }
        isShuttingDown = true

        let workers = active.map { (jobID: $0.key, token: $0.value.token, task: $0.value.task) }
        let pausedCancellationTasks = pendingPausedCancellations.values.map(\.task)
        await withTaskGroup(of: Void.self) { group in
            for worker in workers {
                group.addTask {
                    await self.prepareForShutdown(jobID: worker.jobID, token: worker.token)
                }
            }
            await group.waitForAll()
        }
        for worker in workers {
            await worker.task.value
        }
        for task in pausedCancellationTasks {
            await task.value
        }

        finishEvents()
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func startAvailableJobs() {
        guard !isShuttingDown else { return }

        while active.count < limit, let jobID = queuedIDs.first {
            queuedIDs.removeFirst()
            guard let job = jobs[jobID], job.status == .queued else { continue }
            start(job)
        }
    }

    private func start(_ job: DownloadJob) {
        let token = UUID()
        let runner = self.runner
        let task = Task { [weak self, runner, job] in
            var result: Result<Void, DownloadFailure> = .success(())
            do {
                for try await event in runner.events(for: job) {
                    await self?.receive(event, for: job.id, token: token)
                }
            } catch {
                let failure = error as? DownloadFailure ?? DownloadFailure(
                    category: .downloadFailed,
                    technicalDetail: String(describing: error)
                )
                result = .failure(failure)
            }
            await self?.workerFinished(jobID: job.id, token: token, result: result)
        }

        active[job.id] = ActiveJob(token: token, requestedStop: .none, pendingPause: nil, controlTask: nil, task: task)
        setStatus(.analyzing, for: job.id)
        continuation.yield(.started(job.id))
    }

    private func receive(_ event: DownloadEvent, for jobID: UUID, token: UUID) {
        guard active[jobID]?.token == token else { return }

        if case let .phase(phase) = event {
            setStatus(status(for: phase), for: jobID)
        }
        continuation.yield(.runnerEvent(jobID, event))
    }

    private func workerFinished(jobID: UUID, token: UUID, result: Result<Void, DownloadFailure>) async {
        guard let current = active[jobID], current.token == token else { return }
        if let pendingPause = current.pendingPause {
            _ = await settlePause(
                jobID: jobID,
                workerToken: token,
                generation: pendingPause.generation,
                task: pendingPause.task
            )
        }
        guard let settled = active[jobID], settled.token == token else { return }
        if let controlTask = settled.controlTask {
            await controlTask.value
        }
        guard let worker = active[jobID], worker.token == token else { return }
        active[jobID] = nil

        let finalStatus: DownloadStatus
        switch worker.requestedStop {
        case .pause, .shutdown:
            finalStatus = .paused
        case .cancel:
            finalStatus = .cancelled
        case .none:
            switch result {
            case .success:
                finalStatus = .completed
            case let .failure(failure):
                finalStatus = .failed
                continuation.yield(.failure(jobID, failure))
            }
        }
        setStatus(finalStatus, for: jobID)
        continuation.yield(.stopped(jobID, finalStatus))
        startAvailableJobs()
    }

    private func prepareForShutdown(jobID: UUID, token: UUID) async {
        guard let worker = active[jobID], worker.token == token else { return }
        if let pendingPause = worker.pendingPause {
            _ = await settlePause(
                jobID: jobID,
                workerToken: token,
                generation: pendingPause.generation,
                task: pendingPause.task
            )
        }
        guard let settled = active[jobID], settled.token == token else { return }
        if let controlTask = settled.controlTask {
            await controlTask.value
            guard let latest = active[jobID], latest.token == token else { return }
            if latest.requestedStop == .cancel {
                return
            }
        }

        active[jobID]?.requestedStop = .shutdown
        let runner = self.runner
        let controlTask = Task { await runner.interruptForQuit(jobID: jobID) }
        active[jobID]?.controlTask = controlTask
        await controlTask.value
    }

    private func settlePause(
        jobID: UUID,
        workerToken: UUID,
        generation: UUID,
        task: Task<Bool, Never>
    ) async -> Bool {
        let accepted = await task.value
        guard var worker = active[jobID], worker.token == workerToken,
              worker.pendingPause?.generation == generation else {
            return accepted
        }
        worker.pendingPause = nil
        if accepted, worker.requestedStop == .none {
            worker.requestedStop = .pause
        }
        active[jobID] = worker
        return accepted
    }

    private func finishPausedCancellation(jobID: UUID, generation: UUID) {
        guard pendingPausedCancellations[jobID]?.generation == generation else { return }
        pendingPausedCancellations[jobID] = nil
        setStatus(.cancelled, for: jobID)
        continuation.yield(.stopped(jobID, .cancelled))
    }

    private func removeQueued(_ jobID: UUID) -> Bool {
        guard let index = queuedIDs.firstIndex(of: jobID) else { return false }
        queuedIDs.remove(at: index)
        return true
    }

    private func setStatus(_ status: DownloadStatus, for jobID: UUID) {
        guard var job = jobs[jobID] else { return }
        job.status = status
        job.updatedAt = .now
        jobs[jobID] = job
    }

    private func finishEvents() {
        guard !didFinishEvents else { return }
        didFinishEvents = true
        continuation.finish()
    }

    private static func clampedLimit(_ value: Int) -> Int {
        min(max(value, 1), 10)
    }

    private func status(for phase: DownloadPhase) -> DownloadStatus {
        switch phase {
        case .analyzing:
            .analyzing
        case .downloading:
            .downloading
        case .merging, .postprocessing:
            .merging
        }
    }
}
