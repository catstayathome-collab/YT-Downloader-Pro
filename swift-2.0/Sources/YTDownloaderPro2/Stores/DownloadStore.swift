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
    typealias AnalysisHandler = @Sendable (String, DownloadOptions) async throws -> AnalysisResult

    @Published private(set) var jobs: [DownloadJob]
    @Published var selection: Set<UUID>
    @Published var sidebarSection: DownloadStatus.SidebarSection
    @Published private(set) var analysisState: AnalysisState
    @Published var settings: AppSettings {
        didSet {
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

    private let coordinator: DownloadCoordinator
    private let persistence: PersistenceController
    private let thumbnailCache: ThumbnailCache
    private let diagnostics: DiagnosticsLogger
    private let settingsStore: AppSettingsStore
    private let analyze: AnalysisHandler
    private var eventConsumptionTask: Task<Void, Never>?
    private var coordinatorManagedJobIDs: Set<UUID> = []
    private var didRestorePersistedJobs = false
    private var isPreparingToQuit = false

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
        analyze: @escaping AnalysisHandler
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
        self.analyze = analyze
        consumeCoordinatorEvents()
    }

    deinit {
        eventConsumptionTask?.cancel()
    }

    /// Builds the app-owned store and restores retained records without starting queued work.
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
            analyze: { url, options in
                try await probe.analyze(url: url, options: options)
            }
        )
        store.restorePersistedJobsInBackground()
        return store
    }

    func analyzeURL(_ url: String) async {
        guard !isPreparingToQuit else { return }
        analysisState = .analyzing

        do {
            let result = try await analyze(url, settings.defaultOptions)
            switch result {
            case let .video(video):
                analysisState = .video(video)
            case let .playlist(playlist):
                analysisState = .playlist(playlist)
            }
        } catch {
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
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].status == .queued else {
            return false
        }
        jobs[index].options = options
        jobs[index].updatedAt = .now
        await persist(flush: true)
        return true
    }

    /// Submits retained queued records to the coordinator; newly added records stay queued until this command.
    func startAll() async {
        guard !isPreparingToQuit else { return }
        let queuedJobs = jobs.filter { $0.status == .queued }
        coordinatorManagedJobIDs.formUnion(queuedJobs.map(\.id))
        await coordinator.enqueue(queuedJobs)
    }

    func pauseAll() async {
        for job in jobs where job.status.canPause || coordinatorManagedJobIDs.contains(job.id) {
            await coordinator.pause(job.id)
        }
    }

    func resumeAll() async {
        guard !isPreparingToQuit else { return }
        let pausedIDs = jobs.filter { $0.status == .paused }.map(\.id)
        for jobID in pausedIDs {
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
            transitionJob(at: index, to: .queued)
        }
        await persist(flush: true)
        let resumedJobs = jobs.filter { pausedIDs.contains($0.id) && $0.status == .queued }
        coordinatorManagedJobIDs.formUnion(resumedJobs.map(\.id))
        await coordinator.enqueue(resumedJobs)
    }

    func pause(_ jobID: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if coordinatorManagedJobIDs.contains(jobID) || jobs[index].status.canPause {
            await coordinator.pause(jobID)
        } else if jobs[index].status == .queued {
            transitionJob(at: index, to: .paused)
            await persist(flush: true)
        }
    }

    func resume(_ jobID: UUID) async {
        guard !isPreparingToQuit,
              let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].status == .paused else { return }
        transitionJob(at: index, to: .queued)
        await persist(flush: true)
        coordinatorManagedJobIDs.insert(jobID)
        await coordinator.enqueue(jobs[index])
    }

    func cancel(_ jobID: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
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

    /// Refreshes metadata before returning a failed record to the queue, preserving its original options.
    func retry(_ jobID: UUID) async {
        guard !isPreparingToQuit,
              let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].status == .failed else { return }

        let existing = jobs[index]
        do {
            guard case let .video(video) = try await analyze(existing.sourceURL, existing.options) else {
                throw DownloadFailure(
                    category: .metadataUnavailable,
                    technicalDetail: "Retry analysis returned a playlist instead of the requested media."
                )
            }
            jobs[index].sourceURL = video.sourceURL
            jobs[index].title = video.title
            jobs[index].duration = video.duration
            jobs[index].sourceMetadata = video.sourceURL
            jobs[index].failure = nil
            jobs[index].retryCount += 1
            jobs[index].progress = 0
            jobs[index].downloadedBytes = nil
            jobs[index].totalBytes = nil
            jobs[index].speedBytesPerSecond = nil
            jobs[index].estimatedTimeRemaining = nil
            transitionJob(at: index, to: .queued)
            await persist(flush: true)
            cacheThumbnail(from: video.thumbnailURL, for: existing.id)
        } catch {
            let failure = failure(from: error)
            jobs[index].failure = failure
            jobs[index].updatedAt = .now
            await persist(flush: true)
            await recordDiagnostic(jobID: jobID, stage: "retry-analysis", detail: failure.technicalDetail)
        }
    }

    /// Removes only the retained record and its job-scoped thumbnail cache; completed media remains untouched.
    func removeRecord(_ jobID: UUID) async {
        guard let job = jobs.first(where: { $0.id == jobID }), job.status.isTerminal else { return }
        jobs.removeAll { $0.id == jobID }
        selection.remove(jobID)
        await persist(flush: true)
        do {
            try await thumbnailCache.remove(jobID: jobID)
        } catch {
            await recordDiagnostic(jobID: jobID, stage: "thumbnail-removal", detail: String(describing: error))
        }
    }

    func clearCompleted() async {
        let completedIDs = jobs.filter { $0.status == .completed }.map(\.id)
        guard !completedIDs.isEmpty else { return }
        jobs.removeAll { $0.status == .completed }
        selection.subtract(completedIDs)
        await persist(flush: true)
        for jobID in completedIDs {
            do {
                try await thumbnailCache.remove(jobID: jobID)
            } catch {
                await recordDiagnostic(jobID: jobID, stage: "thumbnail-removal", detail: String(describing: error))
            }
        }
    }

    /// Waits for coordinator shutdown and flushes the final recoverable snapshot before termination.
    func prepareToQuit() async {
        guard !isPreparingToQuit else { return }
        isPreparingToQuit = true
        await coordinator.shutdown()
        await persist(flush: true)
    }

    // Loading is asynchronous so app construction remains synchronous; restored jobs are never auto-submitted.
    private func restorePersistedJobsInBackground() {
        Task { [weak self] in
            await self?.restorePersistedJobs()
        }
    }

    private func restorePersistedJobs() async {
        guard !didRestorePersistedJobs else { return }
        didRestorePersistedJobs = true
        do {
            jobs = Self.recoveredJobs(from: try await persistence.loadJobs())
            selection = selection.intersection(Set(jobs.map(\.id)))
        } catch {
            await recordDiagnostic(jobID: nil, stage: "persistence-recovery", detail: String(describing: error))
        }
    }

    // One cancellable task owns the coordinator stream for the store's lifetime.
    private func consumeCoordinatorEvents() {
        eventConsumptionTask = Task { [weak self, coordinator] in
            for await event in coordinator.events {
                guard !Task.isCancelled else { return }
                await self?.consume(event)
            }
        }
    }

    private func consume(_ event: CoordinatorEvent) async {
        guard !isPreparingToQuit || isCoordinatorStop(event) else { return }
        switch event {
        case let .started(jobID):
            coordinatorManagedJobIDs.insert(jobID)
            return
        case let .runnerEvent(jobID, event):
            await consumeRunnerEvent(event, for: jobID)
        case let .stopped(jobID, status):
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            coordinatorManagedJobIDs.remove(jobID)
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

    // Shutdown is an interruption boundary, not a user-requested merge pause.
    private func markInterruptedJobPaused(at index: Int) {
        jobs[index].status = .paused
        jobs[index].updatedAt = .now
    }

    // Queue, state, output, and failures flush now; high-frequency progress coalesces in PersistenceController.
    private func persist(flush: Bool) async {
        do {
            try await persistence.saveJobs(jobs, flush: flush)
        } catch {
            await recordDiagnostic(jobID: nil, stage: "persistence", detail: String(describing: error))
        }
    }

    private func cacheThumbnail(from url: URL?, for jobID: UUID) {
        guard let url else { return }
        Task { [weak self, thumbnailCache] in
            do {
                let cachedURL = try await thumbnailCache.fetch(remoteURL: url, for: jobID)
                await self?.applyThumbnailPath(cachedURL.path, to: jobID)
            } catch {
                await self?.recordDiagnostic(jobID: jobID, stage: "thumbnail", detail: String(describing: error))
            }
        }
    }

    private func applyThumbnailPath(_ path: String, to jobID: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].thumbnailCachePath = path
        jobs[index].updatedAt = .now
        await persist(flush: true)
    }

    private func recordDiagnostic(jobID: UUID?, stage: String, detail: String?) async {
        try? await diagnostics.record(DiagnosticEvent(jobID: jobID, stage: stage, technicalDetail: detail))
    }

    private func failure(from error: Error) -> DownloadFailure {
        error as? DownloadFailure ?? DownloadFailure(category: .unknown, technicalDetail: String(describing: error))
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

    private func isCoordinatorStop(_ event: CoordinatorEvent) -> Bool {
        if case .stopped = event { return true }
        return false
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
