import Foundation

enum CoordinatorEvent: Equatable, Sendable {
    case started(UUID)
    case runnerEvent(UUID, DownloadEvent)
    case stopped(UUID, DownloadStatus)
}

actor DownloadCoordinator {
    private enum RequestedStop: Equatable {
        case none
        case pause
        case cancel
        case shutdown
    }

    private struct ActiveJob {
        let token: UUID
        var phase: DownloadPhase?
        var requestedStop: RequestedStop
        let task: Task<Void, Never>
    }

    nonisolated let events: AsyncStream<CoordinatorEvent>

    private let runner: any JobRunning
    private let continuation: AsyncStream<CoordinatorEvent>.Continuation
    private var jobs: [UUID: DownloadJob] = [:]
    private var queuedIDs: [UUID] = []
    private var active: [UUID: ActiveJob] = [:]
    private var limit: Int
    private var isShuttingDown = false
    private var didFinishEvents = false

    init(limit: Int = 5, runner: any JobRunning) {
        self.runner = runner
        self.limit = Self.clampedLimit(limit)

        var streamContinuation: AsyncStream<CoordinatorEvent>.Continuation?
        events = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation!
    }

    deinit {
        for worker in active.values {
            worker.task.cancel()
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

        for job in newJobs where job.status == .queued && jobs[job.id] == nil {
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

    func pause(_ jobID: UUID) async {
        guard !isShuttingDown else { return }

        if removeQueued(jobID) {
            setStatus(.paused, for: jobID)
            continuation.yield(.stopped(jobID, .paused))
            return
        }

        guard let worker = active[jobID], worker.requestedStop == .none,
              worker.phase != .merging, worker.phase != .postprocessing else {
            return
        }
        active[jobID]?.requestedStop = .pause
        await runner.pause(jobID: jobID)
        await worker.task.value
    }

    func resume(_ jobID: UUID) {
        guard !isShuttingDown, var job = jobs[jobID], job.status == .paused, !queuedIDs.contains(jobID), active[jobID] == nil else {
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

        if removeQueued(jobID) || jobs[jobID]?.status == .paused {
            setStatus(.cancelled, for: jobID)
            continuation.yield(.stopped(jobID, .cancelled))
            return
        }

        guard let worker = active[jobID], worker.requestedStop == .none else { return }
        active[jobID]?.requestedStop = .cancel
        await runner.cancel(jobID: jobID)
        await worker.task.value
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        let workers = active
        var commands: [(jobID: UUID, useQuitInterruption: Bool)] = []
        var childTasks: [Task<Void, Never>] = []
        for (jobID, worker) in workers {
            guard active[jobID]?.token == worker.token, worker.requestedStop == .none else { continue }
            active[jobID]?.requestedStop = .shutdown
            commands.append((
                jobID: jobID,
                useQuitInterruption: worker.phase == .merging || worker.phase == .postprocessing
            ))
            childTasks.append(worker.task)
        }

        let runner = self.runner
        await withTaskGroup(of: Void.self) { group in
            for command in commands {
                group.addTask {
                    if command.useQuitInterruption {
                        await runner.interruptForQuit(jobID: command.jobID)
                    } else {
                        await runner.pause(jobID: command.jobID)
                    }
                }
            }
            await group.waitForAll()
        }
        for task in childTasks {
            await task.value
        }

        finishEvents()
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
            var completedNormally = true
            do {
                for try await event in runner.events(for: job) {
                    await self?.receive(event, for: job.id, token: token)
                }
            } catch {
                completedNormally = false
            }
            await self?.workerFinished(jobID: job.id, token: token, completedNormally: completedNormally)
        }

        active[job.id] = ActiveJob(token: token, phase: nil, requestedStop: .none, task: task)
        setStatus(.analyzing, for: job.id)
        continuation.yield(.started(job.id))
    }

    private func receive(_ event: DownloadEvent, for jobID: UUID, token: UUID) {
        guard var worker = active[jobID], worker.token == token else { return }

        if case let .phase(phase) = event {
            worker.phase = phase
            active[jobID] = worker
            setStatus(status(for: phase), for: jobID)
        }
        continuation.yield(.runnerEvent(jobID, event))
    }

    private func workerFinished(jobID: UUID, token: UUID, completedNormally: Bool) {
        guard let worker = active[jobID], worker.token == token else { return }
        active[jobID] = nil

        let finalStatus: DownloadStatus
        switch worker.requestedStop {
        case .pause, .shutdown:
            finalStatus = .paused
        case .cancel:
            finalStatus = .cancelled
        case .none:
            finalStatus = completedNormally ? .completed : .failed
        }
        setStatus(finalStatus, for: jobID)
        continuation.yield(.stopped(jobID, finalStatus))
        startAvailableJobs()
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
