import Combine
import Foundation

enum AnalysisState: Equatable {
    case idle
    case analyzing
    case video(VideoAnalysis)
    case playlist(PlaylistAnalysis)
    case failed(DownloadFailure)
}

@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var jobs: [DownloadJob]
    @Published var selection: Set<UUID>
    @Published var sidebarSection: DownloadStatus.SidebarSection
    @Published private(set) var analysisState: AnalysisState
    @Published var settings: AppSettings {
        didSet {
            guard !isPreparingToQuit else { return }
            settingsStore.save(settings)
            Task { [coordinator, settings] in
                await coordinator.setLimit(settings.maximumConcurrentDownloads)
            }
        }
    }

    var filteredJobs: [DownloadJob] {
        guard sidebarSection != .all else { return jobs }
        return jobs.filter { $0.status.sidebarSection == sidebarSection }
    }

    private struct RetryOperation {
        let generation: UInt64
        let task: Task<AnalysisResult, Error>
    }

    private struct ThumbnailOperation {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let coordinator: DownloadCoordinator
    private let persistence: PersistenceController
    private let thumbnailCache: ThumbnailCache
    private let diagnostics: DiagnosticsLogger
    private let settingsStore: AppSettingsStore
    private let metadataAnalyzer: any MetadataAnalyzing
    private var eventConsumptionTask: Task<Void, Never>?
    private var coordinatorManagedJobIDs: Set<UUID> = []
    private var didRestorePersistedJobs = false
    private var isPreparingToQuit = false
    private var quitTask: Task<Void, Error>?
    // Stable generations invalidate suspended work even when cancellation is not cooperative.
    private var nextOperationGeneration: UInt64 = 0
    private var analysisGeneration: UInt64 = 0
    private var analysisTask: Task<AnalysisResult, Error>?
    private var currentRetryGeneration: [UUID: UInt64] = [:]
    private var retryOperations: [UUID: [UInt64: RetryOperation]] = [:]
    private var currentThumbnailGeneration: [UUID: UInt64] = [:]
    private var thumbnailOperations: [UUID: [UInt64: ThumbnailOperation]] = [:]

    init(
        jobs: [DownloadJob] = [],
        selection: Set<UUID> = [],
        sidebarSection: DownloadStatus.SidebarSection = .all,
        analysisState: AnalysisState = .idle,
        settings: AppSettings = .defaults,
        coordinator: DownloadCoordinator,
        persistence: PersistenceController,
        thumbnailCache: ThumbnailCache,
        diagnostics: DiagnosticsLogger,
        settingsStore: AppSettingsStore = AppSettingsStore(),
        metadataAnalyzer: any MetadataAnalyzing
    ) {
        self.jobs = Self.recoveredJobs(from: jobs)
        self.selection = selection
        self.sidebarSection = sidebarSection
        self.analysisState = analysisState
        self.settings = settings.clampedForPersistence()
        self.coordinator = coordinator
        self.persistence = persistence
        self.thumbnailCache = thumbnailCache
        self.diagnostics = diagnostics
        self.settingsStore = settingsStore
        self.metadataAnalyzer = metadataAnalyzer
        consumeCoordinatorEvents()
    }

    deinit {
        eventConsumptionTask?.cancel()
        analysisTask?.cancel()
        let retries = retryOperations.values.flatMap(\.values).map(\.task)
        let thumbnails = thumbnailOperations.values.flatMap(\.values).map(\.task)
        retries.forEach { $0.cancel() }
        thumbnails.forEach { $0.cancel() }

        let analysis = analysisTask
        Task.detached {
            _ = await analysis?.result
            for task in retries {
                _ = await task.result
            }
            for task in thumbnails {
                await task.value
            }
        }
    }

    /// Builds the app-owned Store and restores retained records without submitting queued work.
    static func live(
        bundle: Bundle = .main,
        applicationSupportRoot: URL? = nil,
        settingsStore: AppSettingsStore = AppSettingsStore()
    ) -> DownloadStore {
        let root = applicationSupportRoot ?? Self.defaultApplicationSupportRoot()
        let toolchain = (try? Toolchain.resolve(bundle: bundle.bundleURL)) ?? Self.unavailableToolchain()
        let probe = MetadataProbe(toolchain: toolchain)
        let runner = DownloadRunner(toolchain: toolchain, metadataProbe: probe)
        let coordinator = DownloadCoordinator(limit: settingsStore.load().maximumConcurrentDownloads, runner: runner)
        let store = DownloadStore(
            settings: settingsStore.load(),
            coordinator: coordinator,
            persistence: PersistenceController(root: root),
            thumbnailCache: ThumbnailCache(root: root),
            diagnostics: DiagnosticsLogger(root: root),
            settingsStore: settingsStore,
            metadataAnalyzer: probe
        )
        store.restorePersistedJobsInBackground()
        return store
    }

    /// Replaces any prior URL analysis; only the latest generation may publish a result.
    func analyzeURL(_ url: String) async {
        guard !isPreparingToQuit else { return }
        let generation = makeGeneration()
        analysisGeneration = generation
        analysisState = .analyzing

        let previousTask = analysisTask
        previousTask?.cancel()
        if let previousTask {
            _ = await previousTask.result
        }
        guard ownsAnalysis(generation) else { return }

        let options = settings.defaultOptions
        let analyzer = metadataAnalyzer
        let task = Task { try await analyzer.analyze(url: url, options: options) }
        analysisTask = task
        let result = await task.result
        guard ownsAnalysis(generation) else { return }
        analysisTask = nil

        switch result {
        case let .success(analysis):
            switch analysis {
            case let .video(video):
                analysisState = .video(video)
            case let .playlist(playlist):
                analysisState = .playlist(playlist)
            }
        case let .failure(error):
            let failure = failure(from: error)
            analysisState = .failed(failure)
            await recordDiagnostic(jobID: nil, stage: "analysis", detail: failure.technicalDetail)
        }
    }

    func addVideo(options: DownloadOptions) async {
        guard case let .video(video) = analysisState, !isPreparingToQuit else { return }
        let job = DownloadJob(
            sourceURL: video.sourceURL,
            title: video.title,
            duration: video.duration,
            sourceMetadata: video.sourceURL,
            options: options
        )
        jobs.append(job)
        analysisState = .idle
        await persist(flush: true)
        cacheThumbnail(from: video.thumbnailURL, for: job.id)
    }

    func addPlaylistEntries(selectedIDs: Set<String>, options: DownloadOptions) async {
        guard case let .playlist(playlist) = analysisState, !isPreparingToQuit else { return }
        let newJobs = playlist.entries.compactMap { entry -> (DownloadJob, URL?)? in
            guard selectedIDs.contains(entry.id), entry.isAvailable else { return nil }
            return (
                DownloadJob(
                    sourceURL: entry.sourceURL,
                    playlistID: playlist.id,
                    title: entry.title,
                    duration: entry.duration,
                    sourceMetadata: entry.sourceURL,
                    options: options
                ),
                entry.thumbnailURL
            )
        }
        guard !newJobs.isEmpty else { return }
        jobs.append(contentsOf: newJobs.map(\.0))
        analysisState = .idle
        await persist(flush: true)
        for (job, thumbnailURL) in newJobs {
            cacheThumbnail(from: thumbnailURL, for: job.id)
        }
    }

    func editQueuedJob(_ jobID: UUID, options: DownloadOptions) async -> Bool {
        guard !isPreparingToQuit,
              let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].status == .queued else { return false }
        jobs[index].options = options
        jobs[index].updatedAt = .now
        await persist(flush: true)
        return true
    }

    /// Submits retained queued records; restoration and record creation never auto-start work.
    func startAll() async {
        guard !isPreparingToQuit else { return }
        let queuedJobs = jobs.filter { $0.status == .queued }
        coordinatorManagedJobIDs.formUnion(queuedJobs.map(\.id))
        await coordinator.enqueue(queuedJobs)
    }

    func start(_ jobID: UUID) async {
        guard !isPreparingToQuit,
              let job = jobs.first(where: { $0.id == jobID }),
              job.status == .queued else { return }
        if coordinatorManagedJobIDs.contains(jobID) {
            await coordinator.startNow(jobID)
        } else {
            coordinatorManagedJobIDs.insert(jobID)
            await coordinator.enqueue([job])
            await coordinator.startNow(jobID)
        }
    }

    func pauseAll() async {
        guard !isPreparingToQuit else { return }
        let pausableIDs = jobs.compactMap { job -> UUID? in
            if job.status.canPause { return job.id }
            if job.status == .queued, coordinatorManagedJobIDs.contains(job.id) { return job.id }
            return nil
        }
        for jobID in pausableIDs {
            await coordinator.pause(jobID)
        }
    }

    func resumeAll() async {
        guard !isPreparingToQuit else { return }
        let resumptions = jobs.compactMap { job -> (jobID: UUID, wasManaged: Bool)? in
            guard job.status == .paused else { return nil }
            return (job.id, coordinatorManagedJobIDs.contains(job.id))
        }
        guard !resumptions.isEmpty else { return }
        for resumption in resumptions {
            guard let index = jobs.firstIndex(where: { $0.id == resumption.jobID }) else { continue }
            transitionJob(at: index, to: .queued)
        }
        await persist(flush: true)
        for resumption in resumptions {
            guard !isPreparingToQuit,
                  let job = jobs.first(where: { $0.id == resumption.jobID }),
                  job.status == .queued else { continue }
            if resumption.wasManaged {
                await coordinator.resume(job.id)
            } else {
                coordinatorManagedJobIDs.insert(job.id)
                await coordinator.enqueue(job)
            }
        }
    }

    func pause(_ jobID: UUID) async {
        guard !isPreparingToQuit,
              let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let status = jobs[index].status
        if status.canPause || (status == .queued && coordinatorManagedJobIDs.contains(jobID)) {
            await coordinator.pause(jobID)
        } else if status == .queued {
            transitionJob(at: index, to: .paused)
            await persist(flush: true)
        }
    }

    func resume(_ jobID: UUID) async {
        guard !isPreparingToQuit,
              let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].status == .paused else { return }
        let wasManaged = coordinatorManagedJobIDs.contains(jobID)
        transitionJob(at: index, to: .queued)
        await persist(flush: true)
        guard !isPreparingToQuit,
              let refreshedIndex = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[refreshedIndex].status == .queued else { return }
        if wasManaged {
            await coordinator.resume(jobID)
        } else {
            coordinatorManagedJobIDs.insert(jobID)
            await coordinator.enqueue(jobs[refreshedIndex])
        }
    }

    func cancel(_ jobID: UUID) async {
        guard !isPreparingToQuit,
              let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[index].status {
        case .queued, .paused:
            if coordinatorManagedJobIDs.contains(jobID) {
                await coordinator.cancel(jobID)
            } else {
                transitionJob(at: index, to: .cancelled)
                await persist(flush: true)
            }
        case .analyzing, .downloading, .merging:
            await coordinator.cancel(jobID)
        case .completed, .failed, .cancelled:
            return
        }
    }

    func cancelActiveAndWaiting() async {
        let jobIDs = jobs
            .filter { $0.status == .queued || $0.status.isActive }
            .map(\.id)
        for jobID in jobIDs {
            await cancel(jobID)
        }
    }

    /// Re-analyzes by stable ID; generation checks prevent stale retries from mutating retained history.
    func retry(_ jobID: UUID) async {
        guard !isPreparingToQuit,
              let job = jobs.first(where: { $0.id == jobID }),
              job.status == .failed else { return }
        let generation = makeGeneration()
        currentRetryGeneration[jobID] = generation
        retryOperations[jobID]?.values.forEach { $0.task.cancel() }
        let analyzer = metadataAnalyzer
        let task = Task { try await analyzer.analyze(url: job.sourceURL, options: job.options) }
        retryOperations[jobID, default: [:]][generation] = RetryOperation(generation: generation, task: task)
        let result = await task.result
        retryOperations[jobID]?[generation] = nil
        if retryOperations[jobID]?.isEmpty == true {
            retryOperations[jobID] = nil
        }

        guard ownsRetry(jobID: jobID, generation: generation),
              let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].status == .failed else { return }
        switch result {
        case let .success(analysis):
            guard case let .video(video) = analysis else {
                await retainRetryFailure(
                    DownloadFailure(
                        category: .metadataUnavailable,
                        technicalDetail: "Retry analysis returned a playlist instead of the requested media."
                    ),
                    for: jobID,
                    generation: generation
                )
                return
            }
            guard job.options.selectedFormatsRemainAvailable(in: analysis) else {
                await retainRetryFailure(
                    DownloadFailure(
                        category: .formatReselectionRequired,
                        technicalDetail: "The selected format is no longer available."
                    ),
                    for: jobID,
                    generation: generation
                )
                return
            }
            guard ownsRetry(jobID: jobID, generation: generation),
                  let refreshedIndex = jobs.firstIndex(where: { $0.id == jobID }),
                  jobs[refreshedIndex].status == .failed else { return }
            jobs[refreshedIndex].sourceURL = video.sourceURL
            jobs[refreshedIndex].title = video.title
            jobs[refreshedIndex].duration = video.duration
            jobs[refreshedIndex].sourceMetadata = video.sourceURL
            jobs[refreshedIndex].failure = nil
            jobs[refreshedIndex].retryCount += 1
            jobs[refreshedIndex].progress = 0
            jobs[refreshedIndex].downloadedBytes = nil
            jobs[refreshedIndex].totalBytes = nil
            jobs[refreshedIndex].speedBytesPerSecond = nil
            jobs[refreshedIndex].estimatedTimeRemaining = nil
            transitionJob(at: refreshedIndex, to: .queued)
            currentRetryGeneration[jobID] = nil
            await persist(flush: true)
            guard !isPreparingToQuit, jobs.contains(where: { $0.id == jobID }) else { return }
            cacheThumbnail(from: video.thumbnailURL, for: jobID)
        case let .failure(error):
            await retainRetryFailure(failure(from: error), for: jobID, generation: generation)
        }
    }

    /// Removes retained state and owned cache metadata, never a completed media output.
    func removeRecord(_ jobID: UUID) async {
        guard !isPreparingToQuit,
              let job = jobs.first(where: { $0.id == jobID }),
              job.status.isTerminal else { return }
        invalidateRetry(for: jobID)
        jobs.removeAll { $0.id == jobID }
        selection.remove(jobID)
        await persist(flush: true)
        await cancelThumbnailOperations(for: jobID)
        do {
            try await thumbnailCache.remove(jobID: jobID)
        } catch {
            await recordDiagnostic(jobID: jobID, stage: "thumbnail-removal", detail: String(describing: error))
        }
    }

    func clearCompleted() async {
        guard !isPreparingToQuit else { return }
        let completedIDs = jobs.filter { $0.status == .completed }.map(\.id)
        guard !completedIDs.isEmpty else { return }
        completedIDs.forEach(invalidateRetry)
        jobs.removeAll { $0.status == .completed }
        selection.subtract(completedIDs)
        await persist(flush: true)
        for jobID in completedIDs {
            await cancelThumbnailOperations(for: jobID)
            do {
                try await thumbnailCache.remove(jobID: jobID)
            } catch {
                await recordDiagnostic(jobID: jobID, stage: "thumbnail-removal", detail: String(describing: error))
            }
        }
    }

    func reAdd(_ jobID: UUID) async {
        guard !isPreparingToQuit,
              let job = jobs.first(where: { $0.id == jobID }),
              job.status == .cancelled else { return }
        let replacement = DownloadJob(
            sourceURL: job.sourceURL,
            playlistID: job.playlistID,
            title: job.title,
            duration: job.duration,
            sourceMetadata: job.sourceMetadata,
            options: job.options
        )
        jobs.append(replacement)
        await persist(flush: true)
    }

    /// All callers join one shutdown barrier; a final persistence failure is returned to the app delegate.
    func prepareToQuit() async throws {
        if let quitTask {
            return try await quitTask.value
        }
        isPreparingToQuit = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performQuit()
        }
        quitTask = task
        try await task.value
    }

    // Loading stays asynchronous, but a quit that wins the race prevents late restoration.
    private func restorePersistedJobsInBackground() {
        Task { [weak self] in
            await self?.restorePersistedJobs()
        }
    }

    private func restorePersistedJobs() async {
        guard !didRestorePersistedJobs, !isPreparingToQuit else { return }
        didRestorePersistedJobs = true
        do {
            let restored = Self.recoveredJobs(from: try await persistence.loadJobs())
            guard !isPreparingToQuit else { return }
            jobs = restored
            selection = selection.intersection(Set(jobs.map(\.id)))
        } catch {
            await recordDiagnostic(jobID: nil, stage: "persistence-recovery", detail: String(describing: error))
        }
    }

    /// The consumer lives until coordinator stream completion so shutdown can drain every accepted event.
    private func consumeCoordinatorEvents() {
        eventConsumptionTask = Task { [weak self, coordinator] in
            for await event in coordinator.events {
                guard !Task.isCancelled else { return }
                await self?.consume(event)
            }
        }
    }

    private func consume(_ event: CoordinatorEvent) async {
        switch event {
        case let .started(jobID):
            coordinatorManagedJobIDs.insert(jobID)
            guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].status == .queued else { return }
            transitionJob(at: index, to: .analyzing)
            await persist(flush: true)
        case let .runnerEvent(jobID, event):
            await consumeRunnerEvent(event, for: jobID)
        case let .failure(jobID, failure):
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[index].failure = failure
            jobs[index].updatedAt = .now
            await persist(flush: true)
        case let .stopped(jobID, status):
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            if status != .paused {
                coordinatorManagedJobIDs.remove(jobID)
            }
            if isPreparingToQuit, status == .paused, jobs[index].status.isActive {
                markInterruptedJobPaused(at: index)
            } else {
                transitionJob(at: index, to: status)
            }
            if status == .failed, jobs[index].failure == nil {
                jobs[index].failure = DownloadFailure(
                    category: .unknown,
                    technicalDetail: "The download worker stopped unexpectedly."
                )
            }
            await persist(flush: true)
        }
    }

    private func consumeRunnerEvent(_ event: DownloadEvent, for jobID: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch event {
        case let .reservedBasename(basename):
            jobs[index].reservedOutputBasename = basename
            jobs[index].updatedAt = .now
            await persist(flush: true)
        case let .phase(phase):
            transitionJob(at: index, to: status(for: phase))
            await persist(flush: true)
        case let .progress(progress):
            jobs[index].progress = progress.fraction ?? jobs[index].progress
            jobs[index].downloadedBytes = progress.downloadedBytes ?? jobs[index].downloadedBytes
            jobs[index].totalBytes = progress.totalBytes ?? jobs[index].totalBytes
            jobs[index].speedBytesPerSecond = progress.bytesPerSecond ?? jobs[index].speedBytesPerSecond
            jobs[index].estimatedTimeRemaining = progress.etaSeconds ?? jobs[index].estimatedTimeRemaining
            jobs[index].updatedAt = .now
            await persist(flush: false)
        case let .output(url):
            jobs[index].outputURL = url
            jobs[index].updatedAt = .now
            await persist(flush: true)
        case let .diagnostic(detail):
            await recordDiagnostic(jobID: jobID, stage: "download", detail: detail)
        case .completed:
            return
        }
    }

    private func performQuit() async throws {
        analysisGeneration = makeGeneration()
        let analysis = analysisTask
        analysisTask = nil
        analysis?.cancel()

        currentRetryGeneration.removeAll()
        let retries = retryOperations.values.flatMap(\.values).map(\.task)
        retries.forEach { $0.cancel() }

        currentThumbnailGeneration.removeAll()
        let thumbnails = thumbnailOperations.values.flatMap(\.values).map(\.task)
        thumbnails.forEach { $0.cancel() }

        _ = await analysis?.result
        for task in retries {
            _ = await task.result
        }
        for task in thumbnails {
            await task.value
        }

        await coordinator.shutdown()
        await eventConsumptionTask?.value
        try await persistence.saveJobs(jobs, flush: true)
    }

    private func retainRetryFailure(_ failure: DownloadFailure, for jobID: UUID, generation: UInt64) async {
        guard ownsRetry(jobID: jobID, generation: generation),
              let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].status == .failed else { return }
        jobs[index].failure = failure
        jobs[index].updatedAt = .now
        currentRetryGeneration[jobID] = nil
        await persist(flush: true)
        await recordDiagnostic(jobID: jobID, stage: "retry-analysis", detail: failure.technicalDetail)
    }

    private func transitionJob(at index: Int, to status: DownloadStatus) {
        do {
            try jobs[index].transition(to: status)
        } catch {
            Task { [diagnostics, jobID = jobs[index].id] in
                try? await diagnostics.record(DiagnosticEvent(
                    jobID: jobID,
                    stage: "invalid-transition",
                    technicalDetail: String(describing: error)
                ))
            }
        }
    }

    // Relaunch and quit interruption are recovery boundaries, including non-pausable merge work.
    private func markInterruptedJobPaused(at index: Int) {
        jobs[index].status = .paused
        jobs[index].updatedAt = .now
    }

    /// Durable lifecycle/output/failure saves are immediate; progress-only saves are coalesced.
    private func persist(flush: Bool) async {
        do {
            try await persistence.saveJobs(jobs, flush: flush)
        } catch {
            await recordDiagnostic(jobID: nil, stage: "persistence", detail: String(describing: error))
        }
    }

    private func cacheThumbnail(from url: URL?, for jobID: UUID) {
        guard let url, !isPreparingToQuit, jobs.contains(where: { $0.id == jobID }) else { return }
        let generation = makeGeneration()
        currentThumbnailGeneration[jobID] = generation
        thumbnailOperations[jobID]?.values.forEach { $0.task.cancel() }
        let cache = thumbnailCache
        let task = Task { @MainActor [weak self] in
            do {
                let download = try await cache.download(remoteURL: url)
                guard let self else { return }
                guard self.ownsThumbnail(jobID: jobID, generation: generation) else {
                    self.finishThumbnailOperation(jobID: jobID, generation: generation)
                    return
                }
                let cachedURL = try await cache.install(download, for: jobID)
                guard self.ownsThumbnail(jobID: jobID, generation: generation) else {
                    self.finishThumbnailOperation(jobID: jobID, generation: generation)
                    return
                }
                await self.applyThumbnailPath(cachedURL.path, to: jobID)
            } catch {
                if !Task.isCancelled {
                    await self?.recordDiagnostic(jobID: jobID, stage: "thumbnail", detail: String(describing: error))
                }
            }
            self?.finishThumbnailOperation(jobID: jobID, generation: generation)
        }
        thumbnailOperations[jobID, default: [:]][generation] = ThumbnailOperation(generation: generation, task: task)
    }

    private func applyThumbnailPath(_ path: String, to jobID: UUID) async {
        guard !isPreparingToQuit,
              let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].thumbnailCachePath = path
        jobs[index].updatedAt = .now
        await persist(flush: true)
    }

    private func cancelThumbnailOperations(for jobID: UUID) async {
        currentThumbnailGeneration[jobID] = nil
        let tasks = thumbnailOperations[jobID]?.values.map(\.task) ?? []
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        thumbnailOperations[jobID] = nil
    }

    private func finishThumbnailOperation(jobID: UUID, generation: UInt64) {
        thumbnailOperations[jobID]?[generation] = nil
        if thumbnailOperations[jobID]?.isEmpty == true {
            thumbnailOperations[jobID] = nil
        }
    }

    private func recordDiagnostic(jobID: UUID?, stage: String, detail: String?) async {
        try? await diagnostics.record(DiagnosticEvent(jobID: jobID, stage: stage, technicalDetail: detail))
    }

    private func failure(from error: Error) -> DownloadFailure {
        error as? DownloadFailure ?? DownloadFailure(category: .unknown, technicalDetail: String(describing: error))
    }

    private func makeGeneration() -> UInt64 {
        nextOperationGeneration &+= 1
        return nextOperationGeneration
    }

    private func ownsAnalysis(_ generation: UInt64) -> Bool {
        !isPreparingToQuit && analysisGeneration == generation
    }

    private func ownsRetry(jobID: UUID, generation: UInt64) -> Bool {
        !isPreparingToQuit && currentRetryGeneration[jobID] == generation
    }

    private func ownsThumbnail(jobID: UUID, generation: UInt64) -> Bool {
        !isPreparingToQuit
            && currentThumbnailGeneration[jobID] == generation
            && jobs.contains(where: { $0.id == jobID })
    }

    private func invalidateRetry(for jobID: UUID) {
        currentRetryGeneration[jobID] = nil
        retryOperations[jobID]?.values.forEach { $0.task.cancel() }
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

    private static func recoveredJobs(from jobs: [DownloadJob]) -> [DownloadJob] {
        jobs.map { job in
            var restored = job
            if restored.status.isActive {
                restored.status = .paused
                restored.updatedAt = .now
            }
            return restored
        }
    }

    private static func defaultApplicationSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YT Downloader Pro", isDirectory: true)
    }

    private static func unavailableToolchain() -> Toolchain {
        let unavailable = URL(fileURLWithPath: "/unavailable")
        return Toolchain(ytDLP: unavailable, ffmpeg: unavailable, ffprobe: unavailable, qjs: unavailable)
    }
}
