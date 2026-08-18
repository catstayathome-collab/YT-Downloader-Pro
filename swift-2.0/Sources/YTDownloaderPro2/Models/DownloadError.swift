import Foundation

struct DownloadFailure: Error, Codable, Equatable, Sendable {
    enum Category: String, CaseIterable, Codable, Sendable {
        case invalidURL
        case metadataUnavailable
        case networkUnavailable
        case authenticationRequired
        case unavailableMedia
        case bundledDownloaderUnavailable
        case bundledConverterUnavailable
        case diskFull
        case postProcessingFailed
        case unknown

        var summaryKey: String { "error.\(rawValue).summary" }
        var recoveryKey: String { "error.\(rawValue).recovery" }
    }

    var category: Category
    var summaryKey: String
    var recoverySuggestionKey: String?
    var technicalDetail: String?
    var toolExitCode: Int32?
    var occurredAt: Date

    private static let sensitiveDetailPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(cookie|cookies|authorization|access[-_]?token|po[-_]?token|token|sig|signature)\b(\s*[=:]\s*)((?:bearer\s+)?(?:\"[^\"]*\"|'[^']*'|[^\s&,;]+))"#
    )

    init(
        category: Category,
        summaryKey: String? = nil,
        recoverySuggestionKey: String? = nil,
        technicalDetail: String? = nil,
        toolExitCode: Int32? = nil,
        occurredAt: Date = .now
    ) {
        self.category = category
        self.summaryKey = summaryKey ?? category.summaryKey
        self.recoverySuggestionKey = recoverySuggestionKey ?? category.recoveryKey
        self.technicalDetail = Self.sanitize(technicalDetail)
        self.toolExitCode = toolExitCode
        self.occurredAt = occurredAt
    }

    private static func sanitize(_ detail: String?) -> String? {
        guard let detail else { return nil }

        let range = NSRange(detail.startIndex..., in: detail)
        return sensitiveDetailPattern.stringByReplacingMatches(
            in: detail,
            range: range,
            withTemplate: "$1$2[REDACTED]"
        )
    }
}
