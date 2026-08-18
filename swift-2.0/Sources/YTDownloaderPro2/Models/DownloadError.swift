import Foundation

struct DownloadFailure: Codable, Equatable, Sendable {
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
        self.technicalDetail = technicalDetail
        self.toolExitCode = toolExitCode
        self.occurredAt = occurredAt
    }
}
