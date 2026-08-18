import Foundation

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
}

struct VideoAnalysis: Codable, Equatable, Sendable {
    var sourceURL: String
    var title: String
    var duration: TimeInterval?
    var thumbnailURL: URL?
    var videoFormats: [MediaFormat]
    var audioFormats: [MediaFormat]
}

struct PlaylistEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var sourceURL: String
    var title: String
    var duration: TimeInterval?
    var thumbnailURL: URL?
    var isAvailable: Bool
    var unavailabilityReason: String?

    init(
        id: String,
        sourceURL: String,
        title: String,
        duration: TimeInterval?,
        thumbnailURL: URL?,
        isAvailable: Bool = true,
        unavailabilityReason: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.isAvailable = isAvailable
        self.unavailabilityReason = unavailabilityReason
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceURL
        case title
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
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        unavailabilityReason = try container.decodeIfPresent(String.self, forKey: .unavailabilityReason)
    }
}

struct PlaylistAnalysis: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var entries: [PlaylistEntry]
}
