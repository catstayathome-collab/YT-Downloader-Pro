import Foundation

struct FeatureID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let downloadSingle = Self(rawValue: "download.single")
    static let videoStandard = Self(rawValue: "video.standard")
    static let videoHD = Self(rawValue: "video.hd")
    static let videoUHD = Self(rawValue: "video.uhd")
    static let audioMP3 = Self(rawValue: "audio.mp3")
    static let queueBatch = Self(rawValue: "queue.batch")
    static let playlistExpand = Self(rawValue: "playlist.expand")
    static let subtitleBasic = Self(rawValue: "subtitle.basic")
    static let subtitleAdvanced = Self(rawValue: "subtitle.advanced")
    static let formatPresets = Self(rawValue: "format.presets")
    static let recoveryManual = Self(rawValue: "recovery.manual")
    static let recoveryFull = Self(rawValue: "recovery.full")
    static let historyLocal = Self(rawValue: "history.local")
    static let historySync = Self(rawValue: "history.sync")
    static let supportStandard = Self(rawValue: "support.standard")
    static let supportPriority = Self(rawValue: "support.priority")

    static let known: Set<Self> = [
        .downloadSingle, .videoStandard, .videoHD, .videoUHD, .audioMP3,
        .queueBatch, .playlistExpand, .subtitleBasic, .subtitleAdvanced,
        .formatPresets, .recoveryManual, .recoveryFull, .historyLocal,
        .historySync, .supportStandard, .supportPriority
    ]
}
