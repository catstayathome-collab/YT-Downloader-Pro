import Foundation

protocol JobRunning: Sendable {
    func events(for job: DownloadJob) -> AsyncThrowingStream<DownloadEvent, Error>
    func pause(jobID: UUID) async
    func cancel(jobID: UUID) async
    func interruptForQuit(jobID: UUID) async
}

private final class StreamTerminationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldNotify = true

    func consumeNotification() -> Bool {
        lock.withLock {
            guard shouldNotify else { return false }
            shouldNotify = false
            return true
        }
    }

    func invalidate() {
        lock.withLock { shouldNotify = false }
    }
}

actor DownloadRunner: JobRunning {
    private enum Control: Equatable {
        case none
        case pause
        case cancel
        case quit
    }

    private struct ActiveDownload {
        let token: UUID
        let job: DownloadJob
        let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
        let terminationRelay: StreamTerminationRelay
        var scope: OutputDirectorySecurityScopedAccess?
        var reservation: OutputReservation?
        var process: RunningProcess?
        var phase: DownloadPhase = .analyzing
        var finalOutput: URL?
        var control: Control = .none
    }

    private let toolchain: Toolchain
    private let allocator: OutputNameAllocator
    private let metadataProbe: MetadataProbe
    private let processLauncher: any ProcessLaunching
    private let bookmarks: OutputDirectoryBookmarkService
    private let interruptGraceNanoseconds: UInt64
    private let parser = ProgressParser()

    private var active: [UUID: ActiveDownload] = [:]
    private var cancelledBeforeStart: Set<UUID> = []
    private var cleanupWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(
        toolchain: Toolchain,
        allocator: OutputNameAllocator = OutputNameAllocator(),
        metadataProbe: MetadataProbe,
        processLauncher: any ProcessLaunching = SystemProcessLauncher(),
        bookmarks: OutputDirectoryBookmarkService = .live,
        interruptGraceNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.toolchain = toolchain
        self.allocator = allocator
        self.metadataProbe = metadataProbe
        self.processLauncher = processLauncher
        self.bookmarks = bookmarks
        self.interruptGraceNanoseconds = interruptGraceNanoseconds
    }

    nonisolated func events(for job: DownloadJob) -> AsyncThrowingStream<DownloadEvent, Error> {
        let token = UUID()
        let terminationRelay = StreamTerminationRelay()
        var continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<DownloadEvent, Error> { continuation = $0 }
        continuation?.onTermination = { [weak self, terminationRelay] _ in
            guard terminationRelay.consumeNotification() else { return }
            Task { await self?.consumerTerminated(jobID: job.id, token: token) }
        }
        if let continuation {
            Task { await self.start(job: job, token: token, continuation: continuation, terminationRelay: terminationRelay) }
        }
        return stream
    }

    func pause(jobID: UUID) async {
        guard let activeDownload = active[jobID], activeDownload.phase != .merging else {
            return
        }
        await requestPause(jobID: jobID, control: .pause)
    }

    func cancel(jobID: UUID) async {
        guard let activeDownload = active[jobID] else { return }
        active[jobID]?.control = .cancel
        if let process = activeDownload.process {
            await process.terminate()
        }
        await waitForCleanup(jobID: jobID)
    }

    func interruptForQuit(jobID: UUID) async {
        guard let activeDownload = active[jobID] else { return }
        if activeDownload.phase == .merging || activeDownload.phase == .postprocessing {
            active[jobID]?.control = .quit
            if let process = activeDownload.process {
                await process.interrupt()
                scheduleTerminationIfNeeded(jobID: jobID, token: activeDownload.token, control: .quit)
            }
            await waitForCleanup(jobID: jobID)
            return
        }
        await requestPause(jobID: jobID, control: .quit)
        await waitForCleanup(jobID: jobID)
    }

    private func start(
        job: DownloadJob,
        token: UUID,
        continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation,
        terminationRelay: StreamTerminationRelay
    ) async {
        if cancelledBeforeStart.remove(token) != nil {
            finishStream(continuation: continuation, terminationRelay: terminationRelay, error: nil)
            return
        }
        guard active[job.id] == nil else {
            finishStream(
                continuation: continuation,
                terminationRelay: terminationRelay,
                error: DownloadFailure(category: .unknown, technicalDetail: "This download is already running.")
            )
            return
        }

        active[job.id] = ActiveDownload(
            token: token,
            job: job,
            continuation: continuation,
            terminationRelay: terminationRelay
        )
        await prepareAndRun(jobID: job.id, attempt: 0)
    }

    private func prepareAndRun(jobID: UUID, attempt: Int) async {
        guard var activeDownload = active[jobID] else { return }

        do {
            if activeDownload.scope == nil {
                activeDownload.scope = try outputDirectoryAccess(for: activeDownload.job)
                active[jobID] = activeDownload
            }
            if activeDownload.reservation == nil {
                let directory = try outputDirectory(for: activeDownload.job)
                let reservation = try await allocator.reserve(
                    title: activeDownload.job.title,
                    extension: activeDownload.job.options.outputKind.rawValue,
                    directory: directory,
                    jobID: jobID
                )
                guard var latest = active[jobID] else {
                    await allocator.release(jobID: jobID, removeMarker: false)
                    return
                }
                latest.reservation = reservation
                active[jobID] = latest
                latest.continuation.yield(.phase(.analyzing))
                latest.continuation.yield(.reservedBasename(reservation.baseURL.lastPathComponent))
            }
        } catch {
            await finish(jobID: jobID, error: sanitizedLaunchFailure(error), removeMarker: true)
            return
        }

        guard let prepared = active[jobID] else { return }
        if prepared.control != .none {
            await finishForControl(jobID: jobID)
            return
        }

        var launchedJob = prepared.job
        if let reservation = prepared.reservation {
            launchedJob.reservedOutputBasename = reservation.baseURL.lastPathComponent
            launchedJob.outputURL = reservation.baseURL.appendingPathExtension(launchedJob.options.outputKind.rawValue)
        }

        if var latest = active[jobID], latest.phase != .downloading {
            latest.phase = .downloading
            latest.continuation.yield(.phase(.downloading))
            active[jobID] = latest
        }

        let process: RunningProcess
        do {
            process = try await processLauncher.start(
                executable: toolchain.ytDLP,
                arguments: YouTubeStrategy(toolchain: toolchain).downloadArguments(
                    job: launchedJob,
                    toolchain: toolchain,
                    attempt: attempt
                )
            )
        } catch {
            await finish(jobID: jobID, error: Toolchain.failure(for: "yt-dlp_macos"), removeMarker: true)
            return
        }

        guard var running = active[jobID] else {
            await process.terminate()
            return
        }
        running.process = process
        active[jobID] = running
        if running.control != .none {
            await signal(process: process, for: running.control, jobID: jobID, token: running.token)
        }

        for await event in process.events {
            handleProcessEvent(event, for: jobID)
        }

        let result: ProcessResult
        do {
            result = try await process.result()
        } catch {
            await finish(jobID: jobID, error: Toolchain.failure(for: "yt-dlp_macos"), removeMarker: true)
            return
        }
        await processFinished(jobID: jobID, result: result, attempt: attempt)
    }

    private func handleProcessEvent(_ event: ProcessEvent, for jobID: UUID) {
        guard var activeDownload = active[jobID] else { return }
        let events: [DownloadEvent]
        switch event {
        case let .stdoutLine(line):
            events = parser.parse(line: line)
        case let .stderrLine(line):
            events = parser.parseDiagnostic(line: line)
        case .terminated:
            return
        }

        for event in events {
            switch event {
            case let .phase(phase):
                guard activeDownload.phase != phase else { continue }
                activeDownload.phase = phase
                activeDownload.continuation.yield(event)
            case let .output(url):
                activeDownload.finalOutput = url
            case .completed:
                continue
            default:
                activeDownload.continuation.yield(event)
            }
        }
        active[jobID] = activeDownload
    }

    private func processFinished(jobID: UUID, result: ProcessResult, attempt: Int) async {
        guard var activeDownload = active[jobID] else { return }
        activeDownload.process = nil
        active[jobID] = activeDownload

        if activeDownload.control != .none {
            await finishForControl(jobID: jobID)
            return
        }

        guard result.exitCode == 0 else {
            guard retryableClientFailure(result), attempt + 1 < YouTubeStrategy(toolchain: toolchain).maximumAttempts(for: activeDownload.job.options) else {
                await finish(jobID: jobID, error: failure(for: result, phase: activeDownload.phase), removeMarker: false)
                return
            }

            activeDownload.phase = .analyzing
            activeDownload.continuation.yield(.phase(.analyzing))
            active[jobID] = activeDownload
            guard let analysis = await reanalyze(jobID: jobID, attempt: 0) else { return }
            guard activeDownload.job.options.selectedFormatsRemainAvailable(in: analysis) else {
                await finish(
                    jobID: jobID,
                    error: DownloadFailure(
                        category: .formatReselectionRequired,
                        technicalDetail: "The selected format is no longer available."
                    ),
                    removeMarker: false
                )
                return
            }
            await prepareAndRun(jobID: jobID, attempt: attempt + 1)
            return
        }

        guard let reservation = activeDownload.reservation,
              let finalOutput = activeDownload.finalOutput,
              await verifiedFinalOutput(finalOutput, reservation: reservation, jobID: jobID, outputKind: activeDownload.job.options.outputKind) else {
            await finish(
                jobID: jobID,
                error: DownloadFailure(category: .unknown, technicalDetail: "The download did not produce a verified final file."),
                removeMarker: false
            )
            return
        }

        activeDownload.continuation.yield(.output(finalOutput))
        activeDownload.continuation.yield(.completed)
        active[jobID] = activeDownload
        await finish(jobID: jobID, error: nil, removeMarker: true)
    }

    private func reanalyze(jobID: UUID, attempt: Int) async -> AnalysisResult? {
        guard let activeDownload = active[jobID] else { return nil }
        let request: MetadataAnalysisRequest
        do {
            request = try await metadataProbe.analysisRequest(
                url: activeDownload.job.sourceURL,
                options: activeDownload.job.options,
                attempt: attempt
            )
        } catch let failure as DownloadFailure {
            await finish(jobID: jobID, error: failure, removeMarker: false)
            return nil
        } catch {
            await finish(
                jobID: jobID,
                error: DownloadFailure(category: .metadataUnavailable, technicalDetail: "Video analysis could not be refreshed."),
                removeMarker: false
            )
            return nil
        }

        let process: RunningProcess
        do {
            process = try await processLauncher.start(executable: request.executable, arguments: request.arguments)
        } catch {
            await finish(
                jobID: jobID,
                error: DownloadFailure(category: .metadataUnavailable, technicalDetail: "Video analysis could not start."),
                removeMarker: false
            )
            return nil
        }

        guard var running = active[jobID] else {
            await process.terminate()
            return nil
        }
        running.process = process
        active[jobID] = running
        if running.control != .none {
            await signal(process: process, for: running.control, jobID: jobID, token: running.token)
        }

        for await event in process.events {
            if case let .stderrLine(line) = event {
                for diagnostic in parser.parseDiagnostic(line: line) {
                    if case .diagnostic = diagnostic {
                        active[jobID]?.continuation.yield(diagnostic)
                    }
                }
            }
        }

        let result: ProcessResult
        do {
            result = try await process.result()
        } catch {
            await finish(
                jobID: jobID,
                error: DownloadFailure(category: .metadataUnavailable, technicalDetail: "Video analysis could not start."),
                removeMarker: false
            )
            return nil
        }

        guard var completed = active[jobID] else { return nil }
        completed.process = nil
        active[jobID] = completed
        if completed.control != .none {
            await finishForControl(jobID: jobID)
            return nil
        }
        guard result.exitCode == 0 else {
            let failure = await metadataProbe.analysisFailure(for: result)
            await finish(jobID: jobID, error: failure, removeMarker: false)
            return nil
        }
        do {
            return try await metadataProbe.decodeAnalysisOutput(result.stdout, requestedURL: completed.job.sourceURL)
        } catch let failure as DownloadFailure {
            await finish(jobID: jobID, error: failure, removeMarker: false)
            return nil
        } catch {
            await finish(
                jobID: jobID,
                error: DownloadFailure(category: .metadataUnavailable, technicalDetail: "Video analysis could not be refreshed."),
                removeMarker: false
            )
            return nil
        }
    }

    private func pauseRequestedByConsumer(jobID: UUID, token: UUID) async {
        guard let activeDownload = active[jobID], activeDownload.token == token else { return }
        if activeDownload.phase == .merging || activeDownload.phase == .postprocessing {
            await interruptForQuit(jobID: jobID)
        } else {
            await requestPause(jobID: jobID, control: .pause)
            await waitForCleanup(jobID: jobID)
        }
    }

    private func consumerTerminated(jobID: UUID, token: UUID) async {
        if let activeDownload = active[jobID], activeDownload.token == token {
            await pauseRequestedByConsumer(jobID: jobID, token: token)
        } else {
            cancelledBeforeStart.insert(token)
        }
    }

    private func requestPause(jobID: UUID, control: Control) async {
        guard let activeDownload = active[jobID], activeDownload.phase != .merging, activeDownload.phase != .postprocessing else {
            return
        }
        active[jobID]?.control = control
        if let process = activeDownload.process {
            await signal(process: process, for: control, jobID: jobID, token: activeDownload.token)
        }
    }

    private func signal(process: RunningProcess, for control: Control, jobID: UUID, token: UUID) async {
        switch control {
        case .pause, .quit:
            await process.interrupt()
            scheduleTerminationIfNeeded(jobID: jobID, token: token, control: control)
        case .cancel:
            await process.terminate()
        case .none:
            return
        }
    }

    private func scheduleTerminationIfNeeded(jobID: UUID, token: UUID, control: Control) {
        let grace = interruptGraceNanoseconds
        Task {
            try? await Task.sleep(nanoseconds: grace)
            await self.terminateIfNeeded(jobID: jobID, token: token, control: control)
        }
    }

    private func terminateIfNeeded(jobID: UUID, token: UUID, control: Control) async {
        guard let activeDownload = active[jobID], activeDownload.token == token, activeDownload.control == control,
              let process = activeDownload.process else {
            return
        }
        await process.terminate()
    }

    private func finishForControl(jobID: UUID) async {
        guard let activeDownload = active[jobID] else { return }
        switch activeDownload.control {
        case .cancel:
            await removeIncompleteArtifacts(for: activeDownload)
            await finish(jobID: jobID, error: nil, removeMarker: true)
        case .quit where activeDownload.phase == .merging || activeDownload.phase == .postprocessing:
            await removeMergedDestination(for: activeDownload)
            await finish(jobID: jobID, error: nil, removeMarker: false)
        case .pause, .quit:
            await finish(jobID: jobID, error: nil, removeMarker: false)
        case .none:
            return
        }
    }

    private func finish(jobID: UUID, error: Error?, removeMarker: Bool) async {
        guard let activeDownload = active.removeValue(forKey: jobID) else { return }
        await allocator.release(jobID: jobID, removeMarker: removeMarker)
        activeDownload.scope?.stopAccessing()
        finishStream(
            continuation: activeDownload.continuation,
            terminationRelay: activeDownload.terminationRelay,
            error: error
        )
        let waiters = cleanupWaiters.removeValue(forKey: jobID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func finishStream(
        continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation,
        terminationRelay: StreamTerminationRelay,
        error: Error?
    ) {
        terminationRelay.invalidate()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func waitForCleanup(jobID: UUID) async {
        guard active[jobID] != nil else { return }
        await withCheckedContinuation { continuation in
            cleanupWaiters[jobID, default: []].append(continuation)
        }
    }

    private func outputDirectoryAccess(for job: DownloadJob) throws -> OutputDirectorySecurityScopedAccess {
        guard let bookmark = job.options.outputDirectoryBookmark else {
            throw DownloadFailure(category: .unknown, technicalDetail: "Select a download folder before starting.")
        }
        let resolution: OutputDirectoryBookmarkService.Resolution
        do {
            resolution = try bookmarks.resolveBookmark(bookmark)
        } catch {
            throw DownloadFailure(category: .unknown, technicalDetail: "The selected download folder needs to be chosen again.")
        }
        guard !resolution.isStale, bookmarks.startAccessingSecurityScopedResource(at: resolution.url) else {
            throw DownloadFailure(category: .unknown, technicalDetail: "The selected download folder needs to be chosen again.")
        }
        return OutputDirectorySecurityScopedAccess(url: resolution.url) { [bookmarks] in
            bookmarks.stopAccessingSecurityScopedResource(at: resolution.url)
        }
    }

    private func outputDirectory(for job: DownloadJob) throws -> URL {
        guard let activeDownload = active[job.id], let scope = activeDownload.scope else {
            throw DownloadFailure(category: .unknown, technicalDetail: "The selected download folder is unavailable.")
        }
        return scope.url
    }

    private func verifiedFinalOutput(
        _ url: URL,
        reservation: OutputReservation,
        jobID: UUID,
        outputKind: OutputKind
    ) async -> Bool {
        let finalURL = url.standardizedFileURL
        let directory = reservation.baseURL.deletingLastPathComponent().standardizedFileURL
        let expectedPrefix = reservation.baseURL.lastPathComponent + "."
        guard finalURL.deletingLastPathComponent() == directory,
              finalURL.lastPathComponent.hasPrefix(expectedPrefix),
              finalURL.pathExtension.lowercased() == outputKind.rawValue,
              (try? finalURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return false
        }
        return await allocator.owns(reservation, jobID: jobID)
    }

    private func removeIncompleteArtifacts(for activeDownload: ActiveDownload) async {
        guard let reservation = activeDownload.reservation else { return }
        _ = await allocator.removeOwnedArtifacts(
            incompleteArtifactURLs(for: activeDownload.job, reservation: reservation),
            reservation: reservation,
            jobID: activeDownload.job.id
        )
    }

    private func removeMergedDestination(for activeDownload: ActiveDownload) async {
        guard let reservation = activeDownload.reservation else { return }
        _ = await allocator.removeOwnedArtifacts(
            [reservation.baseURL.appendingPathExtension(activeDownload.job.options.outputKind.rawValue)],
            reservation: reservation,
            jobID: activeDownload.job.id
        )
    }

    private func incompleteArtifactURLs(for job: DownloadJob, reservation: OutputReservation) -> [URL] {
        let base = reservation.baseURL
        let basename = base.lastPathComponent
        let selectedFormatIDs = Set(selectedFormatIDs(for: job.options))
        let outputPrefix = "\(basename).\(job.options.outputKind.rawValue)"
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: base.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )) ?? []

        return contents.filter { url in
            let name = url.lastPathComponent
            if name == "\(outputPrefix).part" || name == "\(outputPrefix).ytdl" {
                return true
            }
            if let suffix = name.dropPrefix("\(outputPrefix).part-Frag"), !suffix.isEmpty,
               suffix.allSatisfy(\.isNumber) {
                return true
            }
            return selectedFormatIDs.contains { formatID in
                isOwnedFormatArtifact(name, basename: basename, formatID: formatID)
            }
        }
    }

    private func isOwnedFormatArtifact(_ name: String, basename: String, formatID: String) -> Bool {
        guard let remainder = name.dropPrefix("\(basename).f\(formatID)."), !remainder.isEmpty else {
            return false
        }
        let components = remainder.split(separator: ".", omittingEmptySubsequences: false)
        guard let fileExtension = components.first, !fileExtension.isEmpty else { return false }
        let suffixes = components.dropFirst().map(String.init)
        if suffixes.isEmpty {
            return true
        }
        guard suffixes.count == 1 else { return false }

        let suffix = suffixes[0]
        if suffix == "part" || suffix == "ytdl" {
            return true
        }
        guard suffix.hasPrefix("part-Frag") else { return false }
        let number = suffix.dropFirst("part-Frag".count)
        return !number.isEmpty && number.allSatisfy { $0.isNumber }
    }

    private func selectedFormatIDs(for options: DownloadOptions) -> [String] {
        var ids: [String] = []
        if case let .format(id, _) = options.videoQuality {
            ids.append(id)
        }
        if case let .format(id, _) = options.audioQuality {
            ids.append(id)
        }
        return ids
    }

    private func retryableClientFailure(_ result: ProcessResult) -> Bool {
        let detail = result.stderr.lowercased()
        return detail.contains("403") || detail.contains("forbidden") || detail.contains("player client") || detail.contains("client validation")
    }

    private func failure(for result: ProcessResult, phase: DownloadPhase) -> DownloadFailure {
        let detail = result.stderr.lowercased()
        let category: DownloadFailure.Category
        if retryableClientFailure(result) {
            category = .authenticationRequired
        } else if detail.contains("network") || detail.contains("timed out") || detail.contains("connection") || detail.contains("dns") {
            category = .networkUnavailable
        } else if detail.contains("disk") || detail.contains("no space") {
            category = .diskFull
        } else if phase == .merging || phase == .postprocessing {
            category = .postProcessingFailed
        } else {
            category = .unknown
        }
        return DownloadFailure(category: category, technicalDetail: "The download did not complete.", toolExitCode: result.exitCode)
    }

    private func sanitizedLaunchFailure(_ error: Error) -> DownloadFailure {
        if let failure = error as? DownloadFailure {
            return failure
        }
        return DownloadFailure(category: .unknown, technicalDetail: "The download could not be prepared.")
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
