import Foundation

enum AnalysisResult: Equatable, Sendable {
    case video(VideoAnalysis)
    case playlist(PlaylistAnalysis)
}

protocol MetadataAnalyzing: Sendable {
    func analyze(url: String, options: DownloadOptions) async throws -> AnalysisResult
}

struct MetadataAnalysisRequest: Sendable {
    let executable: URL
    let arguments: [String]
}

actor MetadataProbe: MetadataAnalyzing {
    private let toolchain: Toolchain
    private let processRunner: any ProcessRunning

    init(toolchain: Toolchain, processRunner: any ProcessRunning = SystemProcessLauncher()) {
        self.toolchain = toolchain
        self.processRunner = processRunner
    }

    func analyze(url: String, options: DownloadOptions) async throws -> AnalysisResult {
        guard isSupportedURL(url) else {
            throw DownloadFailure(category: .invalidURL, technicalDetail: "The media address is not supported.")
        }
        let strategy = YouTubeStrategy(toolchain: toolchain)
        let maximumAttempts = strategy.maximumAttempts(for: options)
        for attempt in 0..<maximumAttempts {
            let result: ProcessResult
            do {
                let request = try analysisRequest(url: url, options: options, attempt: attempt)
                result = try await runAnalysisProcess(request)
            } catch {
                throw DownloadFailure(category: .metadataUnavailable, technicalDetail: "Video analysis could not start.")
            }

            guard result.exitCode == 0 else {
                let failure = failure(for: result)
                if isRetryableClientFailure(result), attempt + 1 < maximumAttempts {
                    continue
                }
                throw failure
            }

            return try decodeAnalysisOutput(result.stdout, requestedURL: url)
        }

        throw DownloadFailure(category: .authenticationRequired, technicalDetail: "YouTube client validation did not succeed.")
    }

    private func runAnalysisProcess(_ request: MetadataAnalysisRequest) async throws -> ProcessResult {
        guard let launcher = processRunner as? any ProcessLaunching else {
            return try await processRunner.run(executable: request.executable, arguments: request.arguments)
        }

        let process = try await launcher.start(executable: request.executable, arguments: request.arguments)
        return try await withTaskCancellationHandler {
            try await process.result()
        } onCancel: {
            Task { await process.terminate() }
        }
    }

    func analysisRequest(url: String, options: DownloadOptions, attempt: Int) throws -> MetadataAnalysisRequest {
        guard isSupportedURL(url) else {
            throw DownloadFailure(category: .invalidURL, technicalDetail: "The media address is not supported.")
        }
        return MetadataAnalysisRequest(
            executable: toolchain.ytDLP,
            arguments: YouTubeStrategy(toolchain: toolchain).analysisArguments(url: url, options: options, attempt: attempt)
        )
    }

    func decodeAnalysisOutput(_ output: String, requestedURL: String) throws -> AnalysisResult {
        try decode(output, requestedURL: requestedURL)
    }

    func analysisFailure(for result: ProcessResult) -> DownloadFailure {
        failure(for: result)
    }

    private func decode(_ output: String, requestedURL: String) throws -> AnalysisResult {
        let metadata: RawMetadata
        do {
            metadata = try JSONDecoder().decode(RawMetadata.self, from: Data(output.utf8))
        } catch {
            throw DownloadFailure(category: .metadataUnavailable, technicalDetail: "Video analysis returned invalid metadata.")
        }

        if metadata.type == "playlist" || metadata.entries != nil {
            return try playlistAnalysis(from: metadata)
        }
        return try videoAnalysis(from: metadata, requestedURL: requestedURL)
    }

    private func videoAnalysis(from metadata: RawMetadata, requestedURL: String) throws -> AnalysisResult {
        let formats = metadata.formats ?? []
        let videoFormats = formats
            .filter(isUsableVideoFormat)
            .deduplicatedByID()
            .map(videoFormat)
            .sorted(by: Self.isHigherVideoQuality)
        let audioFormats = formats
            .filter(isUsableAudioFormat)
            .deduplicatedByID()
            .map(audioFormat)
            .sorted(by: Self.isHigherAudioQuality)

        guard !videoFormats.isEmpty || !audioFormats.isEmpty else {
            throw DownloadFailure(category: .unavailableMedia, technicalDetail: "No usable media formats were returned.")
        }

        return .video(VideoAnalysis(
            sourceURL: metadata.webpageURL ?? metadata.originalURL ?? requestedURL,
            title: metadata.title?.nonEmpty ?? "Untitled video",
            duration: metadata.duration,
            thumbnailURL: metadata.thumbnail.flatMap(URL.init(string:)),
            videoFormats: videoFormats,
            audioFormats: audioFormats
        ))
    }

    private func playlistAnalysis(from metadata: RawMetadata) throws -> AnalysisResult {
        let entries = (metadata.entries ?? []).compactMap { entry -> PlaylistEntry? in
            guard let id = entry?.id?.nonEmpty else { return nil }
            let availability = entry?.availability?.lowercased()
            let isAvailable = availability == nil || availability == "public"
            let sourceURL = entry?.webpageURL ?? entry?.originalURL ?? entry?.url ?? "https://www.youtube.com/watch?v=\(id)"

            return PlaylistEntry(
                id: id,
                sourceURL: sourceURL,
                title: entry?.title?.nonEmpty ?? "Unavailable video",
                duration: entry?.duration,
                thumbnailURL: entry?.thumbnail.flatMap(URL.init(string:)),
                isAvailable: isAvailable,
                unavailabilityReason: isAvailable ? nil : availability
            )
        }

        guard !entries.isEmpty, let id = metadata.id?.nonEmpty else {
            throw DownloadFailure(category: .unavailableMedia, technicalDetail: "The playlist has no selectable entries.")
        }

        return .playlist(PlaylistAnalysis(
            id: id,
            title: metadata.title?.nonEmpty ?? "Untitled playlist",
            entries: entries
        ))
    }

    private func isUsableVideoFormat(_ format: RawFormat) -> Bool {
        isUsableFormat(format)
            && format.videoCodec?.isMediaCodec == true
            && format.audioCodec?.isNoneCodec == true
    }

    private func isUsableAudioFormat(_ format: RawFormat) -> Bool {
        isUsableFormat(format)
            && format.videoCodec?.isNoneCodec == true
            && format.audioCodec?.isMediaCodec == true
    }

    private func isUsableFormat(_ format: RawFormat) -> Bool {
        format.id?.nonEmpty != nil
            && format.url?.isUsableRemoteURL == true
            && format.hasDRM != true
    }

    private func videoFormat(from format: RawFormat) -> MediaFormat {
        let height = format.height ?? 0
        let container = format.container ?? "unknown"
        let note = format.note?.nonEmpty.map { " (\($0))" } ?? ""
        return MediaFormat(
            id: format.id ?? "",
            label: "\(height)p - \(container)\(note)",
            codec: format.videoCodec,
            videoCodec: format.videoCodec,
            audioCodec: nil,
            container: format.container,
            width: format.width,
            height: format.height,
            resolution: "\(format.width ?? 0)x\(height)",
            framesPerSecond: format.framesPerSecond,
            bitrate: format.totalBitrate,
            language: format.language,
            estimatedFileSize: format.fileSize ?? format.estimatedFileSize
        )
    }

    private func audioFormat(from format: RawFormat) -> MediaFormat {
        let container = format.container ?? "unknown"
        let language = format.language?.nonEmpty ?? "original"
        let note = format.note?.nonEmpty ?? "unknown"
        return MediaFormat(
            id: format.id ?? "",
            label: "Audio: \(language) (\(note)) - \(container)",
            codec: format.audioCodec,
            videoCodec: nil,
            audioCodec: format.audioCodec,
            container: format.container,
            width: nil,
            height: nil,
            resolution: nil,
            framesPerSecond: nil,
            bitrate: format.audioBitrate ?? format.totalBitrate,
            language: format.language,
            estimatedFileSize: format.fileSize ?? format.estimatedFileSize
        )
    }

    private static func isHigherVideoQuality(_ left: MediaFormat, _ right: MediaFormat) -> Bool {
        if left.height != right.height { return (left.height ?? 0) > (right.height ?? 0) }
        if left.width != right.width { return (left.width ?? 0) > (right.width ?? 0) }
        if left.framesPerSecond != right.framesPerSecond { return (left.framesPerSecond ?? 0) > (right.framesPerSecond ?? 0) }
        if left.bitrate != right.bitrate { return (left.bitrate ?? 0) > (right.bitrate ?? 0) }
        return left.id < right.id
    }

    private static func isHigherAudioQuality(_ left: MediaFormat, _ right: MediaFormat) -> Bool {
        if left.bitrate != right.bitrate { return (left.bitrate ?? 0) > (right.bitrate ?? 0) }
        if left.estimatedFileSize != right.estimatedFileSize { return (left.estimatedFileSize ?? 0) > (right.estimatedFileSize ?? 0) }
        return left.id < right.id
    }

    private func isSupportedURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), let host = url.host else {
            return false
        }
        return ["http", "https"].contains(scheme) && !host.isEmpty
    }

    private func isRetryableClientFailure(_ result: ProcessResult) -> Bool {
        let detail = result.stderr.lowercased()
        return detail.contains("403") || detail.contains("forbidden") || detail.contains("player client") || detail.contains("client validation")
    }

    private func failure(for result: ProcessResult) -> DownloadFailure {
        let detail = result.stderr.lowercased()
        let category: DownloadFailure.Category
        if isRetryableClientFailure(result) {
            category = .authenticationRequired
        } else if detail.contains("network") || detail.contains("timed out") || detail.contains("connection") || detail.contains("dns") {
            category = .networkUnavailable
        } else if detail.contains("requested format") || detail.contains("unavailable") || detail.contains("private") || detail.contains("removed") {
            category = .unavailableMedia
        } else if detail.contains("unsupported url") || detail.contains("invalid url") {
            category = .invalidURL
        } else {
            category = .metadataUnavailable
        }

        return DownloadFailure(
            category: category,
            technicalDetail: "Video analysis did not complete.",
            toolExitCode: result.exitCode
        )
    }
}

private struct RawMetadata: Decodable {
    let type: String?
    let id: String?
    let webpageURL: String?
    let originalURL: String?
    let title: String?
    let duration: TimeInterval?
    let thumbnail: String?
    let formats: [RawFormat]?
    let entries: [RawPlaylistEntry?]?

    enum CodingKeys: String, CodingKey {
        case type = "_type"
        case id
        case webpageURL = "webpage_url"
        case originalURL = "original_url"
        case title
        case duration
        case thumbnail
        case formats
        case entries
    }
}

private struct RawFormat: Decodable {
    let id: String?
    let note: String?
    let container: String?
    let url: String?
    let hasDRM: Bool?
    let videoCodec: String?
    let audioCodec: String?
    let width: Int?
    let height: Int?
    let framesPerSecond: Double?
    let totalBitrate: Double?
    let audioBitrate: Double?
    let language: String?
    let fileSize: Int64?
    let estimatedFileSize: Int64?

    enum CodingKeys: String, CodingKey {
        case id = "format_id"
        case note = "format_note"
        case container = "ext"
        case url
        case hasDRM = "has_drm"
        case videoCodec = "vcodec"
        case audioCodec = "acodec"
        case width
        case height
        case framesPerSecond = "fps"
        case totalBitrate = "tbr"
        case audioBitrate = "abr"
        case language
        case fileSize = "filesize"
        case estimatedFileSize = "filesize_approx"
    }
}

private struct RawPlaylistEntry: Decodable {
    let id: String?
    let webpageURL: String?
    let originalURL: String?
    let url: String?
    let title: String?
    let duration: TimeInterval?
    let thumbnail: String?
    let availability: String?

    enum CodingKeys: String, CodingKey {
        case id
        case webpageURL = "webpage_url"
        case originalURL = "original_url"
        case url
        case title
        case duration
        case thumbnail
        case availability
    }
}

private extension Array where Element == RawFormat {
    func deduplicatedByID() -> [RawFormat] {
        var seen = Set<String>()
        return filter { format in
            guard let id = format.id?.nonEmpty else { return false }
            return seen.insert(id).inserted
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var isNoneCodec: Bool {
        lowercased() == "none"
    }

    var isMediaCodec: Bool {
        !isEmpty && !isNoneCodec
    }

    var isUsableRemoteURL: Bool {
        guard let url = URL(string: self), let scheme = url.scheme?.lowercased(), let host = url.host else {
            return false
        }
        return ["http", "https"].contains(scheme) && !host.isEmpty
    }
}
