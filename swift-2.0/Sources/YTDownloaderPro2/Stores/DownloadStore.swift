import Combine
import Foundation

enum AnalysisState: Equatable {
    case idle
    case analyzing
    case video(VideoAnalysis)
    case playlist(PlaylistAnalysis)
    case failed(DownloadFailure)
}

struct URLInputSubmissionResult: Equatable, Sendable {
    let acceptedCount: Int
    let rejectedCount: Int
    let duplicateCount: Int
}

struct FailedJobEditSession: Equatable, Sendable, Identifiable {
    let jobID: UUID
    let generation: UInt64
    let analysis: VideoAnalysis
    let options: DownloadOptions

    var id: String { "\(jobID.uuidString)-\(generation)" }
}

struct QueuedJobEditSession: Equatable, Sendable, Identifiable {
    let jobID: UUID
    let generation: UInt64
    let analysis: VideoAnalysis
    let options: DownloadOptions

    var id: String { "\(jobID.uuidString)-\(generation)" }
}

enum OutputDirectorySelectionError: Error, Equatable, LocalizedError {
    case bookmarkCreationFailed

    var errorDescription: String? {
        L10n.string(.mediaFolderSaveFailed, locale: .current)
    }
}

@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var jobs: [DownloadJob]
    @Published var selection: Set<UUID>
    @Published var sidebarSection: DownloadStatus.SidebarSection
    @Published private(set) var analysisState: AnalysisState
    @Published private(set) var updateResult: UpdateResult?
    @Published private(set) var automaticUpdateNotice: UpdateNotice?
    @Published private(set) var manualUpdateNotice: UpdateNotice?
    @Published private(set) var isCheckingForUpdatesManually = false
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
        let visibleJobs = sidebarSection == .all
            ? jobs
            : jobs.filter { $0.status.sidebarSection == sidebarSection }
        return visibleJobs.sorted { $0.createdAt > $1.createdAt }
    }

    private struct RetryOperation {
        let generation: UInt64
        let task: Task<AnalysisResult, Error>
    }

    private struct ThumbnailOperation {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private struct UpdateOperation {
        let generation: UInt64
        let task: Task<UpdateResult, Never>
    }

    private let coordinator: DownloadCoordinator
    private let persistence: PersistenceController
    private let thumbnailCache: ThumbnailCache
    private let diagnostics: DiagnosticsLogger
    private let settingsStore: AppSettingsStore
    private let outputDirectoryBookmarks: OutputDirectoryBookmarkService
    private let metadataAnalyzer: any MetadataAnalyzing
    private let updateChecker: any UpdateChecking
    private let toolchainValidator: (any ToolchainHealthValidating)?
    private var eventConsumptionTask: Task<Void, Never>?
    private var coordinatorManagedJobIDs: Set<UUID> = []
    private var didRestorePersistedJobs = false
    private var isPreparingToQuit = false
    private var quitTask: Task<Void, Error>?
    // Stable generations invalidate suspended work even when cancellation is not cooperative.
    private var nextOperationGeneration: UInt64 = 0
    private var analysisGeneration: UInt64 = 0
    private var analysisTask: Task<AnalysisResult, Error>?
    private var pendingBatchAnalysisIDs: [UUID] = []
    private var currentBatchAnalysisJobID: UUID?
    private var batchAnalysisTask: Task<Void, Never>?
    private var batchAnalysisRequestTask: Task<AnalysisResult, Error>?
    private var currentRetryGeneration: [UUID: UInt64] = [:]
    private var discardingRecordIDs: Set<UUID> = []
    private var currentQueuedEditGeneration: [UUID: UInt64] = [:]
    private var retryOperations: [UUID: [UInt64: RetryOperation]] = [:]
    private var currentThumbnailGeneration: [UUID: UInt64] = [:]
    private var thumbnailOperations: [UUID: [UInt64: ThumbnailOperation]] = [:]
    private var updateGeneration: UInt64 = 0
    private var updateOperation: UpdateOperation?

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
        outputDirectoryBookmarks: OutputDirectoryBookmarkService = .live,
        metadataAnalyzer: any MetadataAnalyzing,
        updateChecker: any UpdateChecking = UpdateChecker.live(),
        toolchainValidator: (any ToolchainHealthValidating)? = nil
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
        self.outputDirectoryBookmarks = outputDirectoryBookmarks
        self.metadataAnalyzer = metadataAnalyzer
        self.updateChecker = updateChecker
        self.toolchainValidator = toolchainValidator
        consumeCoordinatorEvents()
        enqueueRecoveredBatchPlaceholders()
    }

    func optionsBySelectingOutputDirectory(_ directory: URL, in options: DownloadOptions) throws -> DownloadOptions {
        do {
            let bookmark = try outputDirectoryBookmarks.makeBookmark(for: directory)
            guard !bookmark.isEmpty else {
                throw OutputDirectorySelectionError.bookmarkCreationFailed
            }
            var selected = options
            selected.outputDirectoryBookmark = bookmark
            selected.outputDirectoryDisplayPath = directory.path
            var updatedSettings = settings
            updatedSettings.defaultOptions.outputDirectoryBookmark = bookmark
            updatedSettings.defaultOptions.outputDirectoryDisplayPath = directory.path
            settings = updatedSettings
            return selected
        } catch {
            throw OutputDirectorySelectionError.bookmarkCreationFailed
        }
    }

    /// Automatic triggers share one flight; manual work supersedes any older result generation.
    func checkForUpdates(manual: Bool) async {
        guard manual || settings.automaticallyCheckForUpdates else { return }

        if !manual, let operation = updateOperation {
            _ = await operation.task.value
            return
        }

        updateGeneration &+= 1
        let generation = updateGeneration
        if manual {
            updateOperation?.task.cancel()
            isCheckingForUpdatesManually = true
        }
        let task = Task<UpdateResult, Never> { [updateChecker] in
            await updateChecker.check(manual: manual)
        }
        updateOperation = UpdateOperation(generation: generation, task: task)

        let result = await task.value
        guard generation == updateGeneration else { return }
        updateOperation = nil
        if manual {
            isCheckingForUpdatesManually = false
        }

        if !manual {
            switch result {
            case .available, .unsupportedOS:
                break
            case .upToDate, .failed:
                return
            }
        }
        updateResult = result
        let notice = UpdateNotice(
            id: generation,
            result: result,
            origin: manual ? .manual : .automatic
        )
        if manual {
            manualUpdateNotice = notice
        } else {
            automaticUpdateNotice = notice
        }
    }

    func dismissAutomaticUpdateNotice(id: UInt64) {
        guard automaticUpdateNotice?.id == id else { return }
        automaticUpdateNotice = nil
    }

    func dismissManualUpdateNotice(id: UInt64) {
        guard manualUpdateNotice?.id == id else { return }
        manualUpdateNotice = nil
    }

    deinit {
        eventConsumptionTask?.cancel()
        analysisTask?.cancel()
        batchAnalysisRequestTask?.cancel()
        batchAnalysisTask?.cancel()
        updateOperation?.task.cancel()
        let retries = retryOperations.values.flatMap(\.values).map(\.task)
        let thumbnails = thumbnailOperations.values.flatMap(\.values).map(\.task)
        retries.forEach { $0.cancel() }
        thumbnails.forEach { $0.cancel() }

        let analysis = analysisTask
        let batchRequest = batchAnalysisRequestTask
        let batch = batchAnalysisTask
        Task.detached {
            _ = await analysis?.result
            _ = await batchRequest?.result
            await batch?.value
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
        let toolchainValidator = ToolchainValidationGate(toolchain: toolchain)
        let runner = DownloadRunner(
            toolchain: toolchain,
            allocator: OutputNameAllocator(
                lockDirectory: root.appendingPathComponent("Reservation Locks", isDirectory: true)
            ),
            metadataProbe: probe,
            toolchainValidator: toolchainValidator
        )
        let coordinator = DownloadCoordinator(limit: settingsStore.load().maximumConcurrentDownloads, runner: runner)
        let store = DownloadStore(
            settings: settingsStore.load(),
            coordinator: coordinator,
            persistence: PersistenceController(root: root),
            thumbnailCache: ThumbnailCache(root: root),
            diagnostics: DiagnosticsLogger(root: root),
            settingsStore: settingsStore,
            metadataAnalyzer: probe,
            toolchainValidator: toolchainValidator
        )
        Task { _ = try? await toolchainValidator.validate(force: false) }
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
        let toolchainValidator = self.toolchainValidator
        let task = Task {
            try await Self.analyze(
                url: url,
                options: options,
                using: analyzer,
                toolchainValidator: toolchainValidator
            )
        }
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

    func submitURLInput(_ input: String) async -> URLInputSubmissionResult {
        let parsed = MediaURLInputParser.parse(input)
        let submission = URLInputSubmissionResult(
            acceptedCount: parsed.urls.count,
            rejectedCount: parsed.rejectedCount,
            duplicateCount: parsed.duplicateCount
        )
        guard !isPreparingToQuit else { return submission }
        guard !parsed.urls.isEmpty else {
            analysisState = .failed(DownloadFailure(
                category: .invalidURL,
                technicalDetail: "No supported HTTP or HTTPS URL was found in the submitted text."
            ))
            return submission
        }

        if parsed.urls.count == 1, let url = parsed.urls.first {
            await analyzeURL(url)
            return submission
        }

        let createdAt = Date.now
        let placeholders = parsed.urls.enumerated().map { index, url in
            DownloadJob(
                sourceURL: url,
                title: L10n.string(.downloadCenterBatchAnalyzingTitle, locale: settings.locale),
                status: .analyzing,
                options: settings.defaultOptions,
                awaitsBatchAnalysis: true,
                createdAt: createdAt.addingTimeInterval(-Double(index) / 1_000)
            )
        }
        jobs.append(contentsOf: placeholders)
        pendingBatchAnalysisIDs.append(contentsOf: placeholders.map(\.id))
        await persist(flush: true)
        startBatchAnalysisIfNeeded()
        return submission
    }

    func addVideo(options: DownloadOptions) async {
        guard case let .video(video) = analysisState, !isPreparingToQuit else { return }
        let job = DownloadJob(
            sourceURL: video.sourceURL,
            title: video.title,
            titleSource: video.titleSource,
            duration: video.duration,
            sourceMetadata: video.sourceURL,
            options: options
        )
        jobs.append(job)
        analysisState = .idle
        await persist(flush: true)
        cacheThumbnail(from: video.thumbnailURL, for: job.id)
        await automaticallyStartNewJobs([job])
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
                    titleSource: entry.titleSource,
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
        await automaticallyStartNewJobs(newJobs.map(\.0))
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

    func prepareQueuedJobEdit(_ jobID: UUID) async -> QueuedJobEditSession? {
        guard !isPreparingToQuit,
              let job = jobs.first(where: { $0.id == jobID }),
              job.status == .queued else { return nil }
        let generation = makeGeneration()
        currentQueuedEditGeneration[jobID] = generation

        do {
            let result = try await Self.analyze(
                url: job.sourceURL,
                options: job.options,
                using: metadataAnalyzer,
                toolchainValidator: toolchainValidator
            )
            guard currentQueuedEditGeneration[jobID] == generation,
                  jobs.contains(where: { $0.id == jobID && $0.status == .queued }),
                  case let .video(video) = result else { return nil }
            return QueuedJobEditSession(
                jobID: jobID,
                generation: generation,
                analysis: video,
                options: job.options.replacingStaleSelections(with: video)
            )
        } catch {
            guard currentQueuedEditGeneration[jobID] == generation,
                  jobs.contains(where: { $0.id == jobID && $0.status == .queued }) else { return nil }
            let failure = failure(from: error)
            analysisState = .failed(failure)
            await recordDiagnostic(jobID: jobID, stage: "queued-edit-analysis", detail: failure.technicalDetail)
            return nil
        }
    }

    func applyQueuedJobEdit(_ session: QueuedJobEditSession, options: DownloadOptions) async -> Bool {
        guard !isPreparingToQuit,
              currentQueuedEditGeneration[session.jobID] == session.generation,
              let index = jobs.firstIndex(where: { $0.id == session.jobID }),
              jobs[index].status == .queued else { return false }
        currentQueuedEditGeneration[session.jobID] = nil
        jobs[index].options = options
        jobs[index].updatedAt = .now
        await persist(flush: true)
        return true
    }

    /// Submits retained queued records that were restored or deliberately left waiting.
    func startAll() async {
        guard !isPreparingToQuit else { return }
        let queuedJobs = jobs.filter { $0.status == .queued }
        coordinatorManagedJobIDs.formUnion(queuedJobs.map(\.id))
        await coordinator.enqueue(queuedJobs)
    }

    private func automaticallyStartNewJobs(_ newJobs: [DownloadJob]) async {
        guard !isPreparingToQuit else { return }
        let newJobIDs = Set(newJobs.map(\.id))
        let queuedNewJobs = jobs.filter { newJobIDs.contains($0.id) && $0.status == .queued }
        guard !queuedNewJobs.isEmpty else { return }
        coordinatorManagedJobIDs.formUnion(queuedNewJobs.map(\.id))
        await coordinator.enqueue(queuedNewJobs)
    }

    private func startBatchAnalysisIfNeeded() {
        guard batchAnalysisTask == nil, !pendingBatchAnalysisIDs.isEmpty, !isPreparingToQuit else { return }
        batchAnalysisTask = Task { @MainActor [weak self] in
            await self?.processBatchAnalysisQueue()
        }
    }

    private func processBatchAnalysisQueue() async {
        defer {
            currentBatchAnalysisJobID = nil
            batchAnalysisRequestTask = nil
            batchAnalysisTask = nil
        }

        while !Task.isCancelled, !isPreparingToQuit, !pendingBatchAnalysisIDs.isEmpty {
            let jobID = pendingBatchAnalysisIDs.removeFirst()
            guard let job = jobs.first(where: {
                $0.id == jobID && $0.status == .analyzing && $0.awaitsBatchAnalysis
            }) else { continue }

            currentBatchAnalysisJobID = jobID
            let analyzer = metadataAnalyzer
            let toolchainValidator = self.toolchainValidator
            let requestTask = Task {
                try await Self.analyze(
                    url: job.sourceURL,
                    options: job.options,
                    using: analyzer,
                    toolchainValidator: toolchainValidator
                )
            }
            batchAnalysisRequestTask = requestTask
            let result = await requestTask.result
            batchAnalysisRequestTask = nil
            currentBatchAnalysisJobID = nil

            guard !Task.isCancelled, !isPreparingToQuit,
                  jobs.contains(where: {
                      $0.id == jobID && $0.status == .analyzing && $0.awaitsBatchAnalysis
                  }) else { continue }

            switch result {
            case let .success(.video(video)):
                await adoptBatchVideo(video, for: jobID)
            case let .success(.playlist(playlist)):
                await adoptBatchPlaylist(playlist, for: jobID)
            case let .failure(error):
                await failBatchPlaceholder(jobID, with: failure(from: error))
            }
        }
    }

    private func adoptBatchVideo(_ video: VideoAnalysis, for jobID: UUID) async {
        guard let index = jobs.firstIndex(where: {
            $0.id == jobID && $0.status == .analyzing && $0.awaitsBatchAnalysis
        }) else { return }
        jobs[index].sourceURL = video.sourceURL
        jobs[index].title = video.title
        jobs[index].titleSource = video.titleSource
        jobs[index].duration = video.duration
        jobs[index].sourceMetadata = video.sourceURL
        jobs[index].options = jobs[index].options.replacingStaleSelections(with: video)
        jobs[index].failure = nil
        jobs[index].awaitsBatchAnalysis = false
        transitionJob(at: index, to: .queued)
        let job = jobs[index]
        await persist(flush: true)
        guard jobs.contains(where: { $0.id == jobID && $0.status == .queued }) else { return }
        cacheThumbnail(from: video.thumbnailURL, for: jobID)
        await automaticallyStartNewJobs([job])
    }

    private func adoptBatchPlaylist(_ playlist: PlaylistAnalysis, for jobID: UUID) async {
        guard let index = jobs.firstIndex(where: {
            $0.id == jobID && $0.status == .analyzing && $0.awaitsBatchAnalysis
        }) else { return }
        let placeholder = jobs[index]
        let entries = playlist.entries.filter(\.isAvailable)
        guard !entries.isEmpty else {
            var failure = DownloadFailure(
                category: .metadataUnavailable,
                technicalDetail: "The analyzed playlist contained no available entries."
            )
            failure.summaryKey = L10n.Key.downloadCenterBatchPlaylistEmpty.rawValue
            await failBatchPlaceholder(
                jobID,
                with: failure
            )
            return
        }

        let newJobs = entries.enumerated().map { offset, entry in
            DownloadJob(
                sourceURL: entry.sourceURL,
                playlistID: playlist.id,
                title: entry.title,
                titleSource: entry.titleSource,
                duration: entry.duration,
                sourceMetadata: entry.sourceURL,
                options: placeholder.options,
                createdAt: placeholder.createdAt.addingTimeInterval(-Double(offset) / 1_000)
            )
        }
        jobs.replaceSubrange(index...index, with: newJobs)
        selection.remove(jobID)
        await persist(flush: true)
        for (job, entry) in zip(newJobs, entries) {
            cacheThumbnail(from: entry.thumbnailURL, for: job.id)
        }
        await automaticallyStartNewJobs(newJobs)
    }

    private func failBatchPlaceholder(_ jobID: UUID, with failure: DownloadFailure) async {
        guard let index = jobs.firstIndex(where: {
            $0.id == jobID && $0.status == .analyzing && $0.awaitsBatchAnalysis
        }) else { return }
        jobs[index].awaitsBatchAnalysis = false
        jobs[index].failure = failure
        transitionJob(at: index, to: .failed)
        await persist(flush: true)
        await recordDiagnostic(jobID: jobID, stage: "batch-analysis", detail: failure.technicalDetail)
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
        if jobs[index].status == .analyzing, jobs[index].awaitsBatchAnalysis {
            pendingBatchAnalysisIDs.removeAll { $0 == jobID }
            jobs[index].awaitsBatchAnalysis = false
            transitionJob(at: index, to: .cancelled)
            if currentBatchAnalysisJobID == jobID {
                batchAnalysisRequestTask?.cancel()
            }
            await persist(flush: true)
            return
        }
        switch jobs[index].status {
        case .queued:
            if coordinatorManagedJobIDs.contains(jobID) {
                await coordinator.cancel(jobID)
            } else {
                transitionJob(at: index, to: .cancelled)
                await persist(flush: true)
            }
        case .paused:
            if coordinatorManagedJobIDs.contains(jobID) {
                await coordinator.cancel(jobID)
            } else {
                let restoredJob = jobs[index]
                coordinatorManagedJobIDs.insert(jobID)
                await coordinator.cancelRestoredPaused(restoredJob)
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
        guard !isPreparingToQuit, !discardingRecordIDs.contains(jobID),
              let job = jobs.first(where: { $0.id == jobID }),
              job.status == .failed else { return }
        let generation = makeGeneration()
        currentRetryGeneration[jobID] = generation
        retryOperations[jobID]?.values.forEach { $0.task.cancel() }
        let analyzer = metadataAnalyzer
        let toolchainValidator = self.toolchainValidator
        let task = Task {
            try await Self.analyze(
                url: job.sourceURL,
                options: job.options,
                using: analyzer,
                toolchainValidator: toolchainValidator
            )
        }
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
            jobs[refreshedIndex].titleSource = video.titleSource
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

    /// Reanalyzes a failed record with edited credentials/folder settings without mutating it.
    func prepareFailedJobEdit(_ jobID: UUID, options: DownloadOptions) async -> FailedJobEditSession? {
        guard !isPreparingToQuit, !discardingRecordIDs.contains(jobID),
              let job = jobs.first(where: { $0.id == jobID }),
              job.status == .failed,
              job.failure?.category.supportsOptionsRecovery == true else { return nil }
        let generation = makeGeneration()
        currentRetryGeneration[jobID] = generation
        retryOperations[jobID]?.values.forEach { $0.task.cancel() }
        let analyzer = metadataAnalyzer
        let toolchainValidator = self.toolchainValidator
        let task = Task {
            try await Self.analyze(
                url: job.sourceURL,
                options: options,
                using: analyzer,
                toolchainValidator: toolchainValidator
            )
        }
        retryOperations[jobID, default: [:]][generation] = RetryOperation(generation: generation, task: task)
        let result = await task.result
        retryOperations[jobID]?[generation] = nil
        if retryOperations[jobID]?.isEmpty == true {
            retryOperations[jobID] = nil
        }

        guard ownsRetry(jobID: jobID, generation: generation),
              jobs.contains(where: { $0.id == jobID && $0.status == .failed }) else { return nil }
        switch result {
        case let .success(.video(video)):
            return FailedJobEditSession(
                jobID: jobID,
                generation: generation,
                analysis: video,
                options: options.replacingStaleSelections(with: video)
            )
        case .success(.playlist):
            await retainRetryFailure(
                DownloadFailure(
                    category: .metadataUnavailable,
                    technicalDetail: "Recovery analysis returned a playlist instead of the requested media."
                ),
                for: jobID,
                generation: generation
            )
            return nil
        case let .failure(error):
            await retainRetryFailure(failure(from: error), for: jobID, generation: generation)
            return nil
        }
    }

    /// Applies only options selected from this session's fresh metadata snapshot.
    func applyFailedJobEdit(_ session: FailedJobEditSession, options: DownloadOptions) async -> Bool {
        guard !discardingRecordIDs.contains(session.jobID),
              ownsRetry(jobID: session.jobID, generation: session.generation),
              let index = jobs.firstIndex(where: { $0.id == session.jobID }),
              jobs[index].status == .failed else { return false }
        let sanitizedAnalysis = session.analysis.scrubbingMediaURLCredentials()
        let analysis = AnalysisResult.video(sanitizedAnalysis)
        guard options.selectedFormatsRemainAvailable(in: analysis) else {
            await retainRetryFailure(
                DownloadFailure(
                    category: .formatReselectionRequired,
                    technicalDetail: "The edited format was not present in the fresh analysis."
                ),
                for: session.jobID,
                generation: session.generation
            )
            return false
        }

        jobs[index].sourceURL = sanitizedAnalysis.sourceURL
        jobs[index].title = sanitizedAnalysis.title
        jobs[index].titleSource = sanitizedAnalysis.titleSource
        jobs[index].duration = sanitizedAnalysis.duration
        jobs[index].sourceMetadata = sanitizedAnalysis.sourceURL
        jobs[index].options = options
        jobs[index].failure = nil
        jobs[index].retryCount += 1
        jobs[index].progress = 0
        jobs[index].downloadedBytes = nil
        jobs[index].totalBytes = nil
        jobs[index].speedBytesPerSecond = nil
        jobs[index].estimatedTimeRemaining = nil
        transitionJob(at: index, to: .queued)
        currentRetryGeneration[session.jobID] = nil
        await persist(flush: true)
        guard !isPreparingToQuit, jobs.contains(where: { $0.id == session.jobID }) else { return true }
        cacheThumbnail(from: sanitizedAnalysis.thumbnailURL, for: session.jobID)
        return true
    }

    /// Removes retained state and owned cache metadata, never a completed media output.
    func removeRecord(_ jobID: UUID) async {
        guard !isPreparingToQuit, !discardingRecordIDs.contains(jobID),
              let job = jobs.first(where: { $0.id == jobID }),
              job.status.isTerminal else { return }
        discardingRecordIDs.insert(jobID)
        invalidateRetry(for: jobID)
        defer { discardingRecordIDs.remove(jobID) }
        guard await coordinator.cleanupDiscardedRecord(job) else {
            await recordDiagnostic(jobID: jobID, stage: "history-cleanup", detail: "Owned download artifacts could not be released.")
            return
        }
        guard jobs.contains(where: { $0.id == jobID && $0.status.isTerminal }) else { return }
        jobs.removeAll { $0.id == jobID }
        selection.remove(jobID)
        coordinatorManagedJobIDs.remove(jobID)
        await persist(flush: true)
        await cancelThumbnailOperations(for: jobID)
        do {
            try await thumbnailCache.remove(jobID: jobID)
        } catch {
            await recordDiagnostic(jobID: jobID, stage: "thumbnail-removal", detail: String(describing: error))
        }
    }

    /// Clears retained terminal history and thumbnail cache without touching downloaded media.
    func clearHistory() async {
        guard !isPreparingToQuit else { return }
        let terminalJobs = jobs.filter { $0.status.isTerminal && !discardingRecordIDs.contains($0.id) }
        guard !terminalJobs.isEmpty else { return }
        let terminalIDs = Set(terminalJobs.map(\.id))
        discardingRecordIDs.formUnion(terminalIDs)
        terminalIDs.forEach(invalidateRetry)
        defer { discardingRecordIDs.subtract(terminalIDs) }
        var removableIDs: [UUID] = []
        for job in terminalJobs {
            if await coordinator.cleanupDiscardedRecord(job),
               jobs.contains(where: { $0.id == job.id && $0.status.isTerminal }) {
                removableIDs.append(job.id)
            } else {
                await recordDiagnostic(jobID: job.id, stage: "history-cleanup", detail: "Owned download artifacts could not be released.")
            }
        }
        guard !removableIDs.isEmpty else { return }
        let removableIDSet = Set(removableIDs)
        jobs.removeAll { removableIDSet.contains($0.id) }
        selection.subtract(removableIDSet)
        coordinatorManagedJobIDs.subtract(removableIDSet)
        await persist(flush: true)
        for jobID in removableIDs {
            await cancelThumbnailOperations(for: jobID)
            do {
                try await thumbnailCache.remove(jobID: jobID)
            } catch {
                await recordDiagnostic(jobID: jobID, stage: "thumbnail-removal", detail: String(describing: error))
            }
        }
    }

    func reAdd(_ jobID: UUID) async {
        guard !isPreparingToQuit, !discardingRecordIDs.contains(jobID),
              let job = jobs.first(where: { $0.id == jobID }),
              job.status == .cancelled else { return }
        let replacement = DownloadJob(
            sourceURL: job.sourceURL,
            playlistID: job.playlistID,
            title: job.title,
            titleSource: job.titleSource,
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
            enqueueRecoveredBatchPlaceholders()
        } catch {
            let failure = DownloadFailure.classify(
                stderr: String(describing: error),
                context: .persistence
            )
            analysisState = .failed(failure)
            await recordDiagnostic(jobID: nil, stage: "persistence-recovery", detail: failure.technicalDetail)
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
                    category: .downloadFailed,
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

        let batchRequest = batchAnalysisRequestTask
        let batch = batchAnalysisTask
        batchAnalysisRequestTask = nil
        batchAnalysisTask = nil
        batchRequest?.cancel()
        batch?.cancel()

        currentRetryGeneration.removeAll()
        currentQueuedEditGeneration.removeAll()
        let retries = retryOperations.values.flatMap(\.values).map(\.task)
        retries.forEach { $0.cancel() }

        currentThumbnailGeneration.removeAll()
        let thumbnails = thumbnailOperations.values.flatMap(\.values).map(\.task)
        thumbnails.forEach { $0.cancel() }

        _ = await analysis?.result
        _ = await batchRequest?.result
        await batch?.value
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
            if status != .queued {
                currentQueuedEditGeneration[jobs[index].id] = nil
            }
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
        error as? DownloadFailure ?? DownloadFailure.classify(
            stderr: String(describing: error),
            context: .analysis
        )
    }

    private static func analyze(
        url: String,
        options: DownloadOptions,
        using analyzer: any MetadataAnalyzing,
        toolchainValidator: (any ToolchainHealthValidating)?
    ) async throws -> AnalysisResult {
        if let toolchainValidator {
            _ = try await toolchainValidator.validate(force: false)
        }
        do {
            return try await analyzer.analyze(url: url, options: options).scrubbingMediaURLCredentials()
        } catch {
            let failure = error as? DownloadFailure
            let shouldRevalidate = failure?.category == .bundledDownloaderUnavailable
                || failure?.category == .bundledConverterUnavailable
            guard let toolchainValidator, shouldRevalidate else {
                throw error
            }
            do {
                _ = try await toolchainValidator.validate(force: true)
            } catch {
                throw error
            }
            throw error
        }
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

    private func enqueueRecoveredBatchPlaceholders() {
        guard !isPreparingToQuit else { return }
        let knownIDs = Set(pendingBatchAnalysisIDs + [currentBatchAnalysisJobID].compactMap { $0 })
        let recoveredIDs = jobs.compactMap { job -> UUID? in
            guard job.status == .analyzing,
                  job.awaitsBatchAnalysis,
                  !knownIDs.contains(job.id) else { return nil }
            return job.id
        }
        pendingBatchAnalysisIDs.append(contentsOf: recoveredIDs)
        startBatchAnalysisIfNeeded()
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
            var restored = job.scrubbingRetainedMediaURLCredentials()
            if restored.status.isActive, !restored.awaitsBatchAnalysis {
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
