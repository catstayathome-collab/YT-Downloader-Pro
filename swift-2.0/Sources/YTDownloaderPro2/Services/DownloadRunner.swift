import Foundation

protocol JobRunning: Sendable {
    func events(for job: DownloadJob) -> AsyncThrowingStream<DownloadEvent, Error>
    /// Returns true only when a user pause was atomically accepted in a resumable phase.
    @discardableResult func pause(jobID: UUID) async -> Bool
    func cancel(jobID: UUID) async
    @discardableResult func cleanupCancelledJob(_ job: DownloadJob) async -> Bool
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
        var job: DownloadJob
        let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
        let terminationRelay: StreamTerminationRelay
        var scope: OutputDirectorySecurityScopedAccess?
        var reservation: OutputReservation?
        var process: RunningProcess?
        var phase: DownloadPhase = .analyzing
        var finalOutput: URL?
        var workspace: MP4Workspace?
        var sourceVerification: Task<Bool, Error>?
        var control: Control = .none
    }

    private let toolchain: Toolchain
    private let allocator: OutputNameAllocator
    private let metadataProbe: MetadataProbe
    private let processLauncher: any ProcessLaunching
    private let bookmarks: OutputDirectoryBookmarkService
    private let toolchainValidator: (any ToolchainHealthValidating)?
    private let featurePolicyContextProvider: @Sendable () async -> FeaturePolicyContext
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
        toolchainValidator: (any ToolchainHealthValidating)? = nil,
        featurePolicyContextProvider: @escaping @Sendable () async -> FeaturePolicyContext = {
            .publicCompatibility
        },
        interruptGraceNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.toolchain = toolchain
        self.allocator = allocator
        self.metadataProbe = metadataProbe
        self.processLauncher = processLauncher
        self.bookmarks = bookmarks
        self.toolchainValidator = toolchainValidator
        self.featurePolicyContextProvider = featurePolicyContextProvider
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

    @discardableResult
    func pause(jobID: UUID) async -> Bool {
        guard let activeDownload = active[jobID], activeDownload.control == .none,
              activeDownload.phase != .merging, activeDownload.phase != .postprocessing else {
            return false
        }
        active[jobID]?.control = .pause
        activeDownload.sourceVerification?.cancel()
        if let process = activeDownload.process {
            await signal(process: process, for: .pause, jobID: jobID, token: activeDownload.token)
        }
        return true
    }

    func cancel(jobID: UUID) async {
        guard let activeDownload = active[jobID] else { return }
        active[jobID]?.control = .cancel
        activeDownload.sourceVerification?.cancel()
        if let process = activeDownload.process {
            await process.terminate()
        }
        await waitForCleanup(jobID: jobID)
    }

    @discardableResult
    func cleanupCancelledJob(_ job: DownloadJob) async -> Bool {
        if active[job.id] != nil {
            await cancel(jobID: job.id)
            return active[job.id] == nil
        }

        guard job.reservedOutputBasename != nil else { return true }

        let scope: OutputDirectorySecurityScopedAccess
        do {
            scope = try outputDirectoryAccess(for: job)
        } catch {
            return false
        }
        defer { scope.stopAccessing() }

        do {
            let reservation = try await allocator.reserve(
                title: job.title,
                extension: job.options.outputKind.rawValue,
                directory: scope.url,
                jobID: job.id
            )
            let workspaceURL = scope.url.appendingPathComponent(".ytdp-\(job.id.uuidString)")
            if job.options.outputKind == .mp4, FileManager.default.fileExists(atPath: workspaceURL.path) {
                guard await allocator.owns(reservation, jobID: job.id) else { return false }
                let workspace = try MP4Workspace(directory: scope.url, jobID: job.id)
                try workspace.remove()
            }
            let removedArtifacts = await allocator.removeOwnedArtifacts(
                incompleteArtifactURLs(for: job, reservation: reservation),
                reservation: reservation,
                jobID: job.id
            )
            guard removedArtifacts else {
                await allocator.release(jobID: job.id, removeMarker: false)
                return false
            }
            let releasedMarker = await allocator.release(jobID: job.id, removeMarker: true)
            return releasedMarker
        } catch {
            await allocator.release(jobID: job.id, removeMarker: false)
            return false
        }
    }

    func interruptForQuit(jobID: UUID) async {
        guard let activeDownload = active[jobID] else { return }
        if activeDownload.phase == .merging || activeDownload.phase == .postprocessing {
            active[jobID]?.control = .quit
            activeDownload.sourceVerification?.cancel()
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
                error: DownloadFailure(category: .downloadFailed, technicalDetail: "This download is already running."),
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

        let featurePolicyContext = await featurePolicyContextProvider()
        guard let current = active[jobID], current.token == activeDownload.token else { return }
        activeDownload = current
        if current.control != .none { await finishForControl(jobID: jobID); return }
        if case let .denied(denial) = activeDownload.job.options.executionPolicyDecision(
            in: featurePolicyContext
        ) {
            await finish(
                jobID: jobID,
                error: DownloadPolicyDeniedError(denial: denial),
                removeMarker: false
            )
            return
        }

        guard MediaURLValidator.isSupported(activeDownload.job.sourceURL) else {
            await finish(
                jobID: jobID,
                error: DownloadFailure(category: .invalidURL, technicalDetail: "Unsupported or unsafe media URL."),
                removeMarker: true
            )
            return
        }

        if attempt == 0, let toolchainValidator {
            do {
                _ = try await toolchainValidator.validate(force: false)
            } catch {
                let failure = error as? DownloadFailure ?? Toolchain.failure(for: "yt-dlp_macos")
                await finish(jobID: jobID, error: failure, removeMarker: true)
                return
            }
        }

        guard let validated = active[jobID], validated.token == activeDownload.token else { return }
        activeDownload = validated
        if validated.control != .none { await finishForControl(jobID: jobID); return }
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

        if prepared.job.options.outputKind == .mp4, let reservation = prepared.reservation {
            do {
                let workspace = try MP4Workspace(directory: reservation.baseURL.deletingLastPathComponent(), jobID: jobID)
                active[jobID]?.workspace = workspace
                try workspace.prepareRequest(for: prepared.job)
                if try await verifySourceReceipt(workspace: workspace, job: prepared.job, token: prepared.token, write: false) {
                    await finishMP4(jobID: jobID, token: prepared.token)
                    return
                }
                // An interrupted merger must not be mistaken for a reusable finished source.
                if FileManager.default.fileExists(atPath: workspace.source.path) {
                    try FileManager.default.removeItem(at: workspace.source)
                }
            } catch {
                if active[jobID]?.control != Control.none { await finishForControl(jobID: jobID) }
                else { await finish(jobID: jobID, error: mediaPipelineFailure(error), removeMarker: false) }
                return
            }
        }

        guard let launchReady = active[jobID], launchReady.token == prepared.token else { return }
        if launchReady.control != .none { await finishForControl(jobID: jobID); return }
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
                    attempt: attempt,
                    featurePolicy: featurePolicyContext,
                    sourceTemplate: active[jobID]?.workspace?.template
                )
            )
        } catch {
            let failure = await executionFailure(fallbackHelper: "yt-dlp_macos")
            await finish(jobID: jobID, error: failure, removeMarker: true)
            return
        }

        guard var running = active[jobID] else {
            await process.terminate()
            _ = try? await process.result()
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
            let failure = await executionFailure(fallbackHelper: "yt-dlp_macos")
            await finish(jobID: jobID, error: failure, removeMarker: true)
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
            if let failure = await unavailableToolchainAfterRevalidation() {
                await finish(jobID: jobID, error: failure, removeMarker: false)
                return
            }
            guard let latest = active[jobID], latest.token == activeDownload.token else { return }
            activeDownload = latest
            if latest.control != .none { await finishForControl(jobID: jobID); return }
            guard retryableClientFailure(result), attempt + 1 < YouTubeStrategy(toolchain: toolchain).maximumAttempts(for: activeDownload.job.options) else {
                await finish(jobID: jobID, error: failure(for: result, phase: activeDownload.phase), removeMarker: false)
                return
            }

            activeDownload.phase = .analyzing
            activeDownload.continuation.yield(.phase(.analyzing))
            active[jobID] = activeDownload
            guard let analysis = await reanalyze(jobID: jobID, attempt: attempt + 1) else { return }
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
            if case let .video(video) = analysis, var latest = active[jobID] {
                latest.job.options = latest.job.options.refreshingSelectionsForRetry(with: video)
                active[jobID] = latest
            }
            await prepareAndRun(jobID: jobID, attempt: attempt + 1)
            return
        }

        if activeDownload.workspace != nil {
            guard activeDownload.finalOutput?.standardizedFileURL == activeDownload.workspace?.source.standardizedFileURL else {
                await finish(jobID: jobID, error: DownloadFailure(category: .downloadFailed,
                    technicalDetail: "The download did not produce its reserved source file."), removeMarker: false)
                return
            }
            await finishMP4(jobID: jobID, token: activeDownload.token)
            return
        }

        guard let reservation = activeDownload.reservation,
              let finalOutput = activeDownload.finalOutput,
              await verifiedFinalOutput(finalOutput, reservation: reservation, jobID: jobID, outputKind: activeDownload.job.options.outputKind) else {
            await finish(
                jobID: jobID,
                error: DownloadFailure(category: .downloadFailed, technicalDetail: "The download did not produce a verified final file."),
                removeMarker: false
            )
            return
        }

        if let values = try? finalOutput.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize {
            let finalSize = Int64(fileSize)
            activeDownload.continuation.yield(
                .progress(
                    JobProgress(
                        fraction: 1,
                        downloadedBytes: finalSize,
                        totalBytes: finalSize,
                        bytesPerSecond: nil,
                        etaSeconds: 0
                    )
                )
            )
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

        guard let ready = active[jobID], ready.token == activeDownload.token else { return nil }
        if ready.control != .none { await finishForControl(jobID: jobID); return nil }
        let process: RunningProcess
        do {
            process = try await processLauncher.start(executable: request.executable, arguments: request.arguments)
        } catch {
            let failure = await executionFailure(fallbackHelper: "yt-dlp_macos")
            await finish(
                jobID: jobID,
                error: failure,
                removeMarker: false
            )
            return nil
        }

        guard var running = active[jobID] else {
            await process.terminate()
            _ = try? await process.result()
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
            let failure = await executionFailure(fallbackHelper: "yt-dlp_macos")
            await finish(
                jobID: jobID,
                error: failure,
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
            if let failure = await unavailableToolchainAfterRevalidation() {
                await finish(jobID: jobID, error: failure, removeMarker: false)
                return nil
            }
            let failure = await metadataProbe.analysisFailure(for: result)
            await finish(jobID: jobID, error: failure, removeMarker: false)
            return nil
        }
        do {
            let analysis = try await metadataProbe.decodeAnalysisOutput(result.stdout, requestedURL: completed.job.sourceURL)
            guard let latest = active[jobID], latest.token == completed.token else { return nil }
            if latest.control != .none { await finishForControl(jobID: jobID); return nil }
            if case var .video(video) = analysis {
                video.clientStrategy = YouTubeStrategy(toolchain: toolchain).analysisClient(options: completed.job.options, attempt: attempt)
                return .video(video)
            }
            return analysis
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

    private func checkPipeline(jobID: UUID, token: UUID) throws {
        guard let state = active[jobID], state.token == token, state.control == .none else {
            throw CancellationError()
        }
    }

    private func verifySourceReceipt(workspace: MP4Workspace, job: DownloadJob, token: UUID, write: Bool) async throws -> Bool {
        try checkPipeline(jobID: job.id, token: token)
        let worker = Task.detached(priority: .utility) {
            if write {
                try workspace.retainVerifiedSource(for: job)
                return true
            }
            return workspace.hasVerifiedSource(for: job)
        }
        active[job.id]?.sourceVerification = worker
        defer {
            if active[job.id]?.token == token { active[job.id]?.sourceVerification = nil }
        }
        let result = try await worker.value
        try checkPipeline(jobID: job.id, token: token)
        return result
    }

    /// All post-download helpers share the job's process slot and termination handshake.
    private func mediaProcess(jobID: UUID, token: UUID, executable: URL, arguments: [String], duration: Double? = nil) async throws -> ProcessResult {
        try checkPipeline(jobID: jobID, token: token)
        let process = try await processLauncher.start(executable: executable, arguments: arguments)
        guard let state = active[jobID], state.token == token else {
            await process.terminate()
            _ = try? await process.result()
            throw CancellationError()
        }
        active[jobID]?.process = process
        if state.control != .none { await signal(process: process, for: state.control, jobID: jobID, token: token) }
        for await event in process.events {
            guard active[jobID]?.token == token, active[jobID]?.control == Control.none else { continue }
            if case let .stdoutLine(line) = event, let progress = FFmpegProgressParser().parse(line: line, duration: duration) {
                active[jobID]?.continuation.yield(.progress(progress))
            }
        }
        let result: ProcessResult
        do { result = try await process.result() }
        catch {
            if active[jobID]?.token == token { active[jobID]?.process = nil }
            try checkPipeline(jobID: jobID, token: token)
            throw error
        }
        if active[jobID]?.token == token { active[jobID]?.process = nil }
        try checkPipeline(jobID: jobID, token: token)
        return result
    }

    private func probeMedia(_ url: URL, workspace: MP4Workspace, jobID: UUID, token: UUID) async throws -> ProbedMedia {
        try workspace.requireMedia(url)
        let result = try await mediaProcess(jobID: jobID, token: token, executable: toolchain.ffprobe,
            arguments: ["-v", "error", "-threads", "4", "-count_frames", "-show_streams", "-show_format", "-of", "json", url.path])
        guard result.exitCode == 0 else { throw failure(for: result, phase: .postprocessing) }
        // ffprobe can report decoder errors yet return success after a full scan.
        guard result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MP4OutputPlanningError.invalidProbe
        }
        return try JSONDecoder().decode(ProbedMedia.self, from: Data(result.stdout.utf8))
    }

    private func encoderCapabilities(workspace: MP4Workspace, jobID: UUID, token: UUID) async throws -> MP4EncoderCapabilities {
        // Known synthetic input, not a codec listing. Exercise the same 4K encoder settings.
        let source = try JSONDecoder().decode(ProbedMedia.self, from: Data(#"{"streams":[{"index":0,"codec_name":"rawvideo","codec_type":"video","width":3840,"height":2160,"pix_fmt":"yuv420p","color_space":"bt709","color_transfer":"bt709","color_primaries":"bt709","color_range":"tv","duration":"0.5","nb_frames":"12"}]}"#.utf8))
        var capabilities = MP4EncoderCapabilities()
        for encoder in [MP4VideoEncoder.videoToolbox, .libx265] {
            try checkPipeline(jobID: jobID, token: token)
            let output = workspace.directory.appendingPathComponent("probe-\(encoder.rawValue).mp4")
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            defer { try? FileManager.default.removeItem(at: output) }
            let arguments = ["-hide_banner", "-nostdin", "-n", "-f", "lavfi", "-i",
                "testsrc2=size=3840x2160:rate=24:duration=0.5,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=limited", "-an"] + encoder.arguments + [
                "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_trc", "bt709", "-color_primaries", "bt709",
                "-color_range", "tv", "-tag:v", "hvc1", "-f", "mp4", output.path]
            let result = try await mediaProcess(jobID: jobID, token: token, executable: toolchain.ffmpeg, arguments: arguments)
            guard result.exitCode == 0 else { continue }
            do {
                let media = try await probeMedia(output, workspace: workspace, jobID: jobID, token: token)
                try capabilities.recordProbe(encoder: encoder, exitCode: result.exitCode, source: source, output: media)
                return capabilities
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw MP4OutputPlanningError.encoderUnavailable
    }

    private func validateMediaPolicy(_ media: ProbedMedia, jobID: UUID, token: UUID) async throws {
        let context = await featurePolicyContextProvider()
        try checkPipeline(jobID: jobID, token: token)
        if case let .denied(denial) = context.videoDecision(height: media.primaryVideo?.height,
            isAudioOnly: false, isSourceQuality: false) { throw DownloadPolicyDeniedError(denial: denial) }
    }

    private func finishMP4(jobID: UUID, token: UUID) async {
        guard let state = active[jobID], state.token == token, let workspace = state.workspace,
              let reservation = state.reservation else { return }
        do {
            try checkPipeline(jobID: jobID, token: token)
            active[jobID]?.phase = .postprocessing
            state.continuation.yield(.phase(.postprocessing))
            state.continuation.yield(.progress(JobProgress(fraction: nil, downloadedBytes: nil, totalBytes: nil, bytesPerSecond: nil, etaSeconds: nil)))
            state.continuation.yield(.processingStage(.verifying))
            let source = try await probeMedia(workspace.source, workspace: workspace, jobID: jobID, token: token)
            try await validateMediaPolicy(source, jobID: jobID, token: token)
            if case .format = state.job.options.audioQuality, source.primaryAudio == nil {
                throw DownloadFailure(category: .postProcessingFailed,
                    technicalDetail: "The downloaded source is missing the requested audio track.")
            }
            let planner = MP4OutputPlanner()
            _ = try planner.plan(media: source, mode: .originalEncoding, capabilities: MP4EncoderCapabilities())
            _ = try await verifySourceReceipt(workspace: workspace, job: state.job, token: token, write: true)
            var capabilities = MP4EncoderCapabilities()
            let plan: MP4OutputPlan
            do { plan = try planner.plan(media: source, mode: state.job.options.mp4OutputMode, capabilities: capabilities) }
            catch MP4OutputPlanningError.encoderUnavailable {
                capabilities = try await encoderCapabilities(workspace: workspace, jobID: jobID, token: token)
                plan = try planner.plan(media: source, mode: state.job.options.mp4OutputMode, capabilities: capabilities)
            }
            try checkPipeline(jobID: jobID, token: token)
            let destination = reservation.baseURL.appendingPathExtension("mp4")
            if !workspace.isPublished(to: destination) {
                try workspace.discardCandidate()
                state.continuation.yield(.processingStage(plan.videoAction == .copy && plan.audioAction != .aac ? .remuxing : .converting))
                let result = try await mediaProcess(jobID: jobID, token: token, executable: toolchain.ffmpeg,
                    arguments: plan.arguments(input: workspace.source, output: workspace.candidate), duration: source.duration)
                guard result.exitCode == 0 else { throw failure(for: result, phase: .postprocessing) }
            }
            state.continuation.yield(.processingStage(.verifying))
            let output = try await probeMedia(workspace.candidate, workspace: workspace, jobID: jobID, token: token)
            try planner.validate(output: output, source: source, mode: state.job.options.mp4OutputMode)
            try await validateMediaPolicy(output, jobID: jobID, token: token)
            let owned = await allocator.owns(reservation, jobID: jobID)
            try checkPipeline(jobID: jobID, token: token)
            guard owned else { throw MP4OutputPlanningError.outputValidationFailed }
            // No actor suspension between the last control check and atomic publication.
            try workspace.publish(to: destination)
            let size = Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            state.continuation.yield(.progress(JobProgress(fraction: 1, downloadedBytes: size, totalBytes: size, bytesPerSecond: nil, etaSeconds: 0)))
            state.continuation.yield(.output(destination))
            state.continuation.yield(.completed)
            try? workspace.remove()
            await finish(jobID: jobID, error: nil, removeMarker: true)
        } catch {
            guard active[jobID]?.token == token else { return }
            if active[jobID]?.control != Control.none { await finishForControl(jobID: jobID) }
            else {
                await finish(jobID: jobID, error: error is DownloadPolicyDeniedError ? error : mediaPipelineFailure(error), removeMarker: false)
            }
        }
    }

    private func mediaPipelineFailure(_ error: Error) -> DownloadFailure {
        if let failure = error as? DownloadFailure { return failure }
        if let planning = error as? MP4OutputPlanningError {
            if planning == .encoderUnavailable || planning == .encoderProbeFailed {
                return DownloadFailure(category: .compatibleEncoderUnavailable)
            }
            if planning == .unsupportedColorConversion || planning == .unsupportedStreams {
                return DownloadFailure(category: .unsupportedMediaConversion)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return DownloadFailure(category: .diskFull, technicalDetail: "Insufficient space for verified media output.")
        }
        return DownloadFailure(category: .postProcessingFailed, technicalDetail: "Media conversion or final verification failed; the original source has not been published.")
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
        activeDownload.sourceVerification?.cancel()
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
        if let workspace = activeDownload.workspace, let reservation = activeDownload.reservation {
            let owned = await allocator.owns(reservation, jobID: jobID)
            var cleaned = owned
            if owned {
                do {
                    if active[jobID]?.control == .cancel { try workspace.remove() }
                    else {
                        if !workspace.isPublished(to: reservation.baseURL.appendingPathExtension("mp4")) {
                            try workspace.discardCandidate()
                        }
                        if !workspace.hasReceipt(for: activeDownload.job), FileManager.default.fileExists(atPath: workspace.source.path) {
                            try FileManager.default.removeItem(at: workspace.source)
                        }
                    }
                } catch { cleaned = false }
            }
            await finish(jobID: jobID, error: nil, removeMarker: active[jobID]?.control == .cancel && cleaned)
            return
        }
        switch activeDownload.control {
        case .cancel:
            if activeDownload.phase == .merging || activeDownload.phase == .postprocessing {
                await removeMergedDestination(for: activeDownload)
            }
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
        guard let activeDownload = active[jobID] else { return }
        await allocator.release(jobID: jobID, removeMarker: removeMarker)
        activeDownload.scope?.stopAccessing()
        active.removeValue(forKey: jobID)
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
            throw DownloadFailure(category: .outputPermissionDenied, technicalDetail: "Select a download folder before starting.")
        }
        let resolution: OutputDirectoryBookmarkService.Resolution
        do {
            resolution = try bookmarks.resolveBookmark(bookmark)
        } catch {
            throw DownloadFailure(category: .outputPermissionDenied, technicalDetail: "The selected download folder needs to be chosen again.")
        }
        guard !resolution.isStale, bookmarks.startAccessingSecurityScopedResource(at: resolution.url) else {
            throw DownloadFailure(category: .outputPermissionDenied, technicalDetail: "The selected download folder needs to be chosen again.")
        }
        return OutputDirectorySecurityScopedAccess(url: resolution.url) { [bookmarks] in
            bookmarks.stopAccessingSecurityScopedResource(at: resolution.url)
        }
    }

    private func outputDirectory(for job: DownloadJob) throws -> URL {
        guard let activeDownload = active[job.id], let scope = activeDownload.scope else {
            throw DownloadFailure(category: .outputPermissionDenied, technicalDetail: "The selected download folder is unavailable.")
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
        DownloadFailure.classify(
            stderr: result.stderr,
            context: phase == .merging || phase == .postprocessing ? .postProcessing : .download,
            exitCode: result.exitCode
        )
    }

    private func sanitizedLaunchFailure(_ error: Error) -> DownloadFailure {
        if let failure = error as? DownloadFailure {
            return failure
        }
        return DownloadFailure.classify(
            stderr: "A bundled download component could not be launched.",
            context: .toolchain
        )
    }

    private func executionFailure(fallbackHelper: String) async -> DownloadFailure {
        await unavailableToolchainAfterRevalidation() ?? Toolchain.failure(for: fallbackHelper)
    }

    private func unavailableToolchainAfterRevalidation() async -> DownloadFailure? {
        guard let toolchainValidator else { return nil }
        do {
            _ = try await toolchainValidator.validate(force: true)
            return nil
        } catch let failure as DownloadFailure {
            return failure
        } catch {
            return Toolchain.failure(for: "yt-dlp_macos")
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
