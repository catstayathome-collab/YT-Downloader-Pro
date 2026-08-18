import Foundation

struct MediaFormat: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var label: String
    var codec: String?
    var container: String?
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
}

struct PlaylistAnalysis: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var entries: [PlaylistEntry]
}
