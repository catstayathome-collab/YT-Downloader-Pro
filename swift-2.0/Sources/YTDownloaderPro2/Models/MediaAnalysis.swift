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
