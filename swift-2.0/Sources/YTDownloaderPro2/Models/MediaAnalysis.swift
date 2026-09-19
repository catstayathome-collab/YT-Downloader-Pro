import Foundation

enum MediaTitleSource: String, Codable, Equatable, Sendable {
    case metadata
    case synthesizedUntitledVideo
    case synthesizedUntitledPlaylist
    case synthesizedUnavailableVideo
}

struct MediaFormat: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var label: String
    var codec: String?
    var videoCodec: String?
    var audioCodec: String?
    var container: String?
    var width: Int?
    var height: Int?
    var resolution: String?
    var framesPerSecond: Double?
    var bitrate: Double?
    var language: String?
    var estimatedFileSize: Int64?
    var note: String?
}

struct PersistedFormatPresentation: Codable, Equatable, Sendable {
    var id: String
    var codec: String?
    var videoCodec: String?
    var audioCodec: String?
    var container: String?
    var width: Int?
    var height: Int?
    var resolution: String?
    var framesPerSecond: Double?
    var bitrate: Double?
    var language: String?
    var estimatedFileSize: Int64?
    var note: String?

    init(_ format: MediaFormat) {
        id = format.id
        codec = format.codec
        videoCodec = format.videoCodec
        audioCodec = format.audioCodec
        container = format.container
        width = format.width
        height = format.height
        resolution = format.resolution
        framesPerSecond = format.framesPerSecond
        bitrate = format.bitrate
        language = format.language
        estimatedFileSize = format.estimatedFileSize
        note = format.note
    }

    func mediaFormat(fallbackLabel: String) -> MediaFormat {
        MediaFormat(
            id: id,
            label: fallbackLabel,
            codec: codec,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            container: container,
            width: width,
            height: height,
            resolution: resolution,
            framesPerSecond: framesPerSecond,
            bitrate: bitrate,
            language: language,
            estimatedFileSize: estimatedFileSize,
            note: note
        )
    }
}

enum QuickTimeMP4Compatibility {
    static let ytDLPVideoSelector = "bestvideo[vcodec^=avc1][ext=mp4]"
    static let ytDLPAudioSelector = "bestaudio[acodec^=mp4a][ext=m4a]"
    static let ytDLPProgressiveSelector = "best[vcodec^=avc1][acodec^=mp4a][ext=mp4]"
    static let ytDLPFormatSelector = "\(ytDLPVideoSelector)+\(ytDLPAudioSelector)/\(ytDLPProgressiveSelector)"

    static func supportsVideo(_ format: MediaFormat) -> Bool {
        supportsVideo(codec: format.videoCodec, container: format.container)
    }

    static func supportsAudio(_ format: MediaFormat) -> Bool {
        supportsAudio(codec: format.audioCodec, container: format.container)
    }

    static func supportsVideo(_ format: PersistedFormatPresentation?) -> Bool {
        guard let format else { return false }
        return supportsVideo(codec: format.videoCodec, container: format.container)
    }

    static func supportsAudio(_ format: PersistedFormatPresentation?) -> Bool {
        guard let format else { return false }
        return supportsAudio(codec: format.audioCodec, container: format.container)
    }

    private static func supportsVideo(codec: String?, container: String?) -> Bool {
        guard let codec = codec?.lowercased(), let container = container?.lowercased() else { return false }
        return ["mp4", "m4v", "mov"].contains(container)
            && (codec.hasPrefix("avc1") || codec.hasPrefix("h264"))
    }

    private static func supportsAudio(codec: String?, container: String?) -> Bool {
        guard let codec = codec?.lowercased(), let container = container?.lowercased() else { return false }
        return ["m4a", "mp4", "mov"].contains(container)
            && (codec.hasPrefix("mp4a") || codec.hasPrefix("aac"))
    }
}

struct VideoAnalysis: Codable, Equatable, Sendable {
    var sourceURL: String
    var title: String
    var titleSource: MediaTitleSource?
    var duration: TimeInterval?
    var thumbnailURL: URL?
    var videoFormats: [MediaFormat]
    var audioFormats: [MediaFormat]
}

struct PlaylistEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var sourceURL: String
    var title: String
    var titleSource: MediaTitleSource?
    var duration: TimeInterval?
    var thumbnailURL: URL?
    var isAvailable: Bool
    var unavailabilityReason: String?

    init(
        id: String,
        sourceURL: String,
        title: String,
        titleSource: MediaTitleSource? = nil,
        duration: TimeInterval?,
        thumbnailURL: URL?,
        isAvailable: Bool = true,
        unavailabilityReason: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.titleSource = titleSource
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.isAvailable = isAvailable
        self.unavailabilityReason = unavailabilityReason
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceURL
        case title
        case titleSource
        case duration
        case thumbnailURL
        case isAvailable
        case unavailabilityReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        title = try container.decode(String.self, forKey: .title)
        titleSource = try container.decodeIfPresent(MediaTitleSource.self, forKey: .titleSource)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        unavailabilityReason = try container.decodeIfPresent(String.self, forKey: .unavailabilityReason)
    }
}

struct PlaylistAnalysis: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var titleSource: MediaTitleSource?
    var entries: [PlaylistEntry]
}

extension AnalysisResult {
    func scrubbingMediaURLCredentials() -> AnalysisResult {
        switch self {
        case let .video(video):
            .video(video.scrubbingMediaURLCredentials())
        case let .playlist(playlist):
            .playlist(playlist.scrubbingMediaURLCredentials())
        }
    }
}

extension VideoAnalysis {
    func scrubbingMediaURLCredentials() -> VideoAnalysis {
        var scrubbed = self
        scrubbed.sourceURL = MediaURLValidator.credentialFreeEquivalent(of: sourceURL) ?? sourceURL
        if let thumbnailURL, !MediaURLValidator.isSupported(thumbnailURL.absoluteString) {
            scrubbed.thumbnailURL = nil
        }
        return scrubbed
    }
}

extension PlaylistAnalysis {
    func scrubbingMediaURLCredentials() -> PlaylistAnalysis {
        var scrubbed = self
        scrubbed.entries = entries.map { $0.scrubbingMediaURLCredentials() }
        return scrubbed
    }
}

extension PlaylistEntry {
    func scrubbingMediaURLCredentials() -> PlaylistEntry {
        var scrubbed = self
        scrubbed.sourceURL = MediaURLValidator.credentialFreeEquivalent(of: sourceURL) ?? sourceURL
        if let thumbnailURL, !MediaURLValidator.isSupported(thumbnailURL.absoluteString) {
            scrubbed.thumbnailURL = nil
        }
        return scrubbed
    }
}
