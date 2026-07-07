import Foundation

enum DownloadStatus: String, Codable, CaseIterable {
    case queued
    case analyzing
    case downloading
    case paused
    case merging
    case completed
    case failed
    case cancelled

    var label: String {
        switch self {
        case .queued: "Queued"
        case .analyzing: "Analyzing"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .merging: "Merging"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

enum DownloadFormat: String, Codable, CaseIterable, Identifiable {
    case mp4
    case mp3

    var id: String { rawValue }
}

enum SubtitleMode: String, Codable, CaseIterable, Identifiable {
    case none
    case download
    case embed

    var id: String { rawValue }
}

enum CookiesMode: String, Codable, CaseIterable, Identifiable {
    case none
    case chrome
    case safari

    var id: String { rawValue }
}

struct DownloadOptions: Codable, Equatable {
    var format: DownloadFormat = .mp4
    var audioOnly: Bool = false
    var quality: String = "best"
    var subtitleMode: SubtitleMode = .none
    var embedThumbnail: Bool = false
    var cookiesMode: CookiesMode = .chrome
    var outputDirectory: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
}

struct DownloadJob: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String = "Untitled"
    var status: DownloadStatus = .queued
    var progress: Double = 0
    var speed: String = "--"
    var outputPath: String = ""
    var options = DownloadOptions()
    var error: String?
    var createdAt = Date()
    var updatedAt = Date()
}
