import Foundation

enum VideoQuality: Codable, Equatable, Sendable {
    case best
    case format(id: String, label: String)
}

enum AudioQuality: Codable, Equatable, Sendable {
    case best
    case format(id: String, label: String)
}

enum OutputKind: String, Codable, Sendable {
    case mp4
    case mp3
}

enum SubtitleMode: String, Codable, Sendable {
    case none
    case download
    case embed
}

enum CookieMode: String, Codable, Sendable {
    case none
    case chrome
    case safari
}

struct DownloadOptions: Codable, Equatable, Sendable {
    var outputKind: OutputKind
    var videoQuality: VideoQuality
    var audioQuality: AudioQuality
    var subtitleMode: SubtitleMode
    var subtitleLanguage: String?
    var embedThumbnail: Bool
    var embedMetadata: Bool
    var cookies: CookieMode
    var outputDirectoryBookmark: Data?
    var outputDirectoryDisplayPath: String?

    static let defaults = DownloadOptions(
        outputKind: .mp4,
        videoQuality: .best,
        audioQuality: .best,
        subtitleMode: .none,
        subtitleLanguage: nil,
        embedThumbnail: false,
        embedMetadata: false,
        cookies: .none,
        outputDirectoryBookmark: nil,
        outputDirectoryDisplayPath: nil
    )

    init(
        outputKind: OutputKind = .mp4,
        videoQuality: VideoQuality = .best,
        audioQuality: AudioQuality = .best,
        subtitleMode: SubtitleMode = .none,
        subtitleLanguage: String? = nil,
        embedThumbnail: Bool = false,
        embedMetadata: Bool = false,
        cookies: CookieMode = .none,
        outputDirectoryBookmark: Data? = nil,
        outputDirectoryDisplayPath: String? = nil
    ) {
        self.outputKind = outputKind
        self.videoQuality = videoQuality
        self.audioQuality = audioQuality
        self.subtitleMode = subtitleMode
        self.subtitleLanguage = subtitleLanguage
        self.embedThumbnail = embedThumbnail
        self.embedMetadata = embedMetadata
        self.cookies = cookies
        self.outputDirectoryBookmark = outputDirectoryBookmark
        self.outputDirectoryDisplayPath = outputDirectoryDisplayPath
    }
}
