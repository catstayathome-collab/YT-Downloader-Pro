import Foundation

enum VideoQuality: Codable, Equatable, Sendable {
    case best
    case format(id: String, label: String?)

    static func == (left: VideoQuality, right: VideoQuality) -> Bool {
        switch (left, right) {
        case (.best, .best): true
        case let (.format(leftID, _), .format(rightID, _)): leftID == rightID
        default: false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: QualityCodingKeys.self)
        if container.contains(.best) {
            self = .best
        } else {
            let payload = try container.decode(FormatQualityPayload.self, forKey: .format)
            self = .format(id: payload.id, label: payload.label)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: QualityCodingKeys.self)
        switch self {
        case .best:
            try container.encode(EmptyQualityPayload(), forKey: .best)
        case let .format(id, _):
            try container.encode(FormatQualityPayload(id: id, label: nil), forKey: .format)
        }
    }
}

enum AudioQuality: Codable, Equatable, Sendable {
    case best
    case format(id: String, label: String?)

    static func == (left: AudioQuality, right: AudioQuality) -> Bool {
        switch (left, right) {
        case (.best, .best): true
        case let (.format(leftID, _), .format(rightID, _)): leftID == rightID
        default: false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: QualityCodingKeys.self)
        if container.contains(.best) {
            self = .best
        } else {
            let payload = try container.decode(FormatQualityPayload.self, forKey: .format)
            self = .format(id: payload.id, label: payload.label)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: QualityCodingKeys.self)
        switch self {
        case .best:
            try container.encode(EmptyQualityPayload(), forKey: .best)
        case let .format(id, _):
            try container.encode(FormatQualityPayload(id: id, label: nil), forKey: .format)
        }
    }
}

private enum QualityCodingKeys: String, CodingKey {
    case best
    case format
}

private struct EmptyQualityPayload: Codable {}

private struct FormatQualityPayload: Codable {
    let id: String
    let label: String?
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
    var selectedVideoFormat: PersistedFormatPresentation?
    var selectedAudioFormat: PersistedFormatPresentation?
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
        selectedVideoFormat: nil,
        selectedAudioFormat: nil,
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
        selectedVideoFormat: PersistedFormatPresentation? = nil,
        selectedAudioFormat: PersistedFormatPresentation? = nil,
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
        self.selectedVideoFormat = selectedVideoFormat ?? Self.legacyVideoFormat(for: videoQuality).map(PersistedFormatPresentation.init)
        self.selectedAudioFormat = selectedAudioFormat ?? Self.legacyAudioFormat(for: audioQuality).map(PersistedFormatPresentation.init)
        self.subtitleMode = subtitleMode
        self.subtitleLanguage = subtitleLanguage
        self.embedThumbnail = embedThumbnail
        self.embedMetadata = embedMetadata
        self.cookies = cookies
        self.outputDirectoryBookmark = outputDirectoryBookmark
        self.outputDirectoryDisplayPath = outputDirectoryDisplayPath
    }

    func selectedFormatsRemainAvailable(in analysis: AnalysisResult) -> Bool {
        guard case let .video(video) = analysis else { return false }
        let videoIDs = Set(video.videoFormats.map(\.id))
        let audioIDs = Set(video.audioFormats.map(\.id))
        if case let .format(id, _) = videoQuality, outputKind == .mp4, !videoIDs.contains(id) {
            return false
        }
        if case let .format(id, _) = audioQuality, !audioIDs.contains(id) {
            return false
        }
        return true
    }

    mutating func selectOutputKind(_ kind: OutputKind) {
        outputKind = kind
        if kind == .mp3, subtitleMode == .embed {
            subtitleMode = .download
        }
    }

    mutating func selectVideoFormat(_ format: MediaFormat?) {
        selectedVideoFormat = format.map(PersistedFormatPresentation.init)
        videoQuality = format.map { .format(id: $0.id, label: $0.label) } ?? .best
    }

    mutating func selectAudioFormat(_ format: MediaFormat?) {
        selectedAudioFormat = format.map(PersistedFormatPresentation.init)
        audioQuality = format.map { .format(id: $0.id, label: $0.label) } ?? .best
    }

    func normalizedForExecution() -> DownloadOptions {
        var normalized = self
        normalized.selectOutputKind(outputKind)
        normalized.reconcileStructuredSelections()
        return normalized
    }

    func replacingStaleSelections(with analysis: VideoAnalysis) -> DownloadOptions {
        var refreshed = normalizedForExecution()
        let selectedVideoID = videoQuality.formatID
        let selectedAudioID = audioQuality.formatID
        if let format = analysis.videoFormats.first(where: { $0.id == selectedVideoID }) ?? analysis.videoFormats.first {
            refreshed.selectVideoFormat(format)
        } else {
            refreshed.selectVideoFormat(nil)
        }
        if let format = analysis.audioFormats.first(where: { $0.id == selectedAudioID }) ?? analysis.audioFormats.first {
            refreshed.selectAudioFormat(format)
        } else {
            refreshed.selectAudioFormat(nil)
        }
        return refreshed
    }

    private mutating func reconcileStructuredSelections() {
        switch videoQuality {
        case .best:
            selectedVideoFormat = nil
        case let .format(id, label):
            if selectedVideoFormat?.id != id {
                selectedVideoFormat = label.flatMap {
                    Self.legacyVideoFormat(id: id, label: $0).map(PersistedFormatPresentation.init)
                }
            }
        }
        switch audioQuality {
        case .best:
            selectedAudioFormat = nil
        case let .format(id, label):
            if selectedAudioFormat?.id != id {
                selectedAudioFormat = label.flatMap {
                    Self.legacyAudioFormat(id: id, label: $0).map(PersistedFormatPresentation.init)
                }
            }
        }
    }

    private static func legacyVideoFormat(for quality: VideoQuality) -> MediaFormat? {
        guard case let .format(id, label?) = quality else { return nil }
        return legacyVideoFormat(id: id, label: label)
    }

    private static func legacyAudioFormat(for quality: AudioQuality) -> MediaFormat? {
        guard case let .format(id, label?) = quality else { return nil }
        return legacyAudioFormat(id: id, label: label)
    }

    private static func legacyVideoFormat(id: String, label: String) -> MediaFormat? {
        guard let captures = captures(in: label, pattern: #"^(\d+)p\s*-\s*([^\s(]+)(?:\s*\((.+)\))?$"#),
              let height = Int(captures[0]) else { return nil }
        return MediaFormat(
            id: id,
            label: label,
            videoCodec: "legacy-video",
            container: captures[1],
            height: height,
            note: captures[2].isEmpty ? nil : captures[2]
        )
    }

    private static func legacyAudioFormat(id: String, label: String) -> MediaFormat? {
        guard let captures = captures(
            in: label,
            pattern: #"^Audio:\s*(.+?)\s*\((.+?)\)\s*-\s*([^\s]+)$"#
        ) else { return nil }
        return MediaFormat(
            id: id,
            label: label,
            audioCodec: "legacy-audio",
            container: captures[2],
            language: captures[0].lowercased() == "original" ? nil : captures[0],
            note: captures[1].lowercased() == "unknown" ? nil : captures[1]
        )
    }

    private static func captures(in value: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }

    private enum CodingKeys: String, CodingKey {
        case outputKind
        case videoQuality
        case audioQuality
        case selectedVideoFormat
        case selectedAudioFormat
        case subtitleMode
        case subtitleLanguage
        case embedThumbnail
        case embedMetadata
        case cookies
        case outputDirectoryBookmark
        case outputDirectoryDisplayPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            outputKind: try container.decode(OutputKind.self, forKey: .outputKind),
            videoQuality: try container.decode(VideoQuality.self, forKey: .videoQuality),
            audioQuality: try container.decode(AudioQuality.self, forKey: .audioQuality),
            selectedVideoFormat: try container.decodeIfPresent(PersistedFormatPresentation.self, forKey: .selectedVideoFormat),
            selectedAudioFormat: try container.decodeIfPresent(PersistedFormatPresentation.self, forKey: .selectedAudioFormat),
            subtitleMode: try container.decode(SubtitleMode.self, forKey: .subtitleMode),
            subtitleLanguage: try container.decodeIfPresent(String.self, forKey: .subtitleLanguage),
            embedThumbnail: try container.decode(Bool.self, forKey: .embedThumbnail),
            embedMetadata: try container.decode(Bool.self, forKey: .embedMetadata),
            cookies: try container.decode(CookieMode.self, forKey: .cookies),
            outputDirectoryBookmark: try container.decodeIfPresent(Data.self, forKey: .outputDirectoryBookmark),
            outputDirectoryDisplayPath: try container.decodeIfPresent(String.self, forKey: .outputDirectoryDisplayPath)
        )
    }
}

private extension VideoQuality {
    var formatID: String? {
        guard case let .format(id, _) = self else { return nil }
        return id
    }
}

private extension AudioQuality {
    var formatID: String? {
        guard case let .format(id, _) = self else { return nil }
        return id
    }
}
