import Foundation

struct DownloadFailure: Error, Codable, Equatable, Sendable {
    enum Category: String, CaseIterable, Codable, Sendable {
        case invalidURL
        case metadataUnavailable
        case networkUnavailable
        case authenticationRequired
        case formatReselectionRequired
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
    private static let sensitiveHeaderPattern = try! NSRegularExpression(
        pattern: #"(?im)^([ \t]*(?:cookie|authorization)[ \t]*:[ \t]*)[^\r\n]*"#
    )
    private static let remoteURLPattern = try! NSRegularExpression(
        pattern: #"(?i)https?://[^\s\"'<>]+"#
    )
    private static let sensitiveArgumentFlags: Set<String> = [
        "--add-header",
        "--ap-password",
        "--ap-username",
        "--cookies",
        "--cookies-from-browser",
        "--extractor-args",
        "--http-header",
        "--netrc-location",
        "--password",
        "--twofactor",
        "--username",
        "--video-password"
    ]

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

    static func sanitizedTechnicalDetail(_ detail: String) -> String {
        sanitize(detail) ?? ""
    }

    static func sanitizedDiagnosticDetail(_ detail: String) -> String {
        redactQueryValues(in: sanitizedTechnicalDetail(detail))
    }

    static func sanitizedDiagnosticArguments(_ arguments: [String]) -> [String] {
        var sanitized: [String] = []
        var redactNextArgument = false

        for argument in arguments {
            if redactNextArgument {
                sanitized.append("[REDACTED]")
                redactNextArgument = false
                continue
            }

            let flagAndValue = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let flag = String(flagAndValue[0]).lowercased()
            if sensitiveArgumentFlags.contains(flag) {
                if flagAndValue.count == 2 {
                    sanitized.append("\(flagAndValue[0])=[REDACTED]")
                } else {
                    sanitized.append(argument)
                    redactNextArgument = true
                }
                continue
            }

            sanitized.append(sanitizedDiagnosticDetail(argument))
        }

        return sanitized
    }

    private static func sanitize(_ detail: String?) -> String? {
        guard let detail else { return nil }

        let range = NSRange(detail.startIndex..., in: detail)
        let redactedHeaders = sensitiveHeaderPattern.stringByReplacingMatches(
            in: detail,
            range: range,
            withTemplate: "$1[REDACTED]"
        )
        let headerRange = NSRange(redactedHeaders.startIndex..., in: redactedHeaders)
        return sensitiveDetailPattern.stringByReplacingMatches(
            in: redactedHeaders,
            range: headerRange,
            withTemplate: "$1$2[REDACTED]"
        )
    }

    private static func redactQueryValues(in detail: String) -> String {
        let range = NSRange(detail.startIndex..., in: detail)
        let matches = remoteURLPattern.matches(in: detail, range: range)
        guard !matches.isEmpty else { return detail }

        var result = detail
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let urlText = String(result[matchRange])
            guard var components = URLComponents(string: urlText), let queryItems = components.queryItems, !queryItems.isEmpty else {
                continue
            }
            components.queryItems = queryItems.map { URLQueryItem(name: $0.name, value: "[REDACTED]") }
            guard let sanitizedURL = components.string else { continue }
            result.replaceSubrange(matchRange, with: sanitizedURL)
        }
        return result
    }
}
