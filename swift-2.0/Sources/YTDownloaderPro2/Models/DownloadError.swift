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
    private static let structuredURLPattern = try! NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s\"'<>]+"#
    )
    private static let sensitiveArgumentFlags: Set<String> = [
        "-2",
        "-p",
        "-u",
        "--add-header",
        "--ap-password",
        "--ap-username",
        "--cookies",
        "--cookies-from-browser",
        "--extractor-args",
        "--http-header",
        "--netrc-cmd",
        "--netrc-location",
        "--password",
        "--twofactor",
        "--username",
        "--video-password"
    ]
    private static let URLArgumentFlags: Set<String> = [
        "--geo-verification-proxy",
        "--proxy"
    ]
    private static let sensitiveFlagInTextPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)((?:-[up2]|(?i:--(?:add-header|ap-password|ap-username|cookies|cookies-from-browser|extractor-args|http-header|netrc-cmd|netrc-location|password|twofactor|username|video-password)))(?:\s+|=))(?:(?:\"[^\"]*\"|'[^']*')|\S+)"#
    )
    private static let cookiePathPattern = try! NSRegularExpression(
        pattern: #"(?i)(\bcookies?(?:[-_ ]+file)?(?:\s+(?:from|to|at|path))?\s*[=:]?\s*)(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|(?:~?/|/)[^\s,;\r\n]+)"#
    )
    private static let credentialProsePattern = try! NSRegularExpression(
        pattern: #"(?i)\b(username|user|password|passwd)\b(\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#
    )
    private static let bearerPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(bearer|basic)(\s+)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#
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

    static func sanitizedTechnicalDetail(_ detail: String) -> String {
        sanitize(detail) ?? ""
    }

    static func sanitizedDiagnosticDetail(_ detail: String) -> String {
        let sanitizedURLs = sanitizeStructuredURLs(in: sanitizedTechnicalDetail(detail))
        let sanitizedFlags = replacingMatches(
            sensitiveFlagInTextPattern,
            in: sanitizedURLs,
            withTemplate: "$1[REDACTED]"
        )
        let sanitizedCookiePaths = replacingMatches(
            cookiePathPattern,
            in: sanitizedFlags,
            withTemplate: "$1[REDACTED]"
        )
        let sanitizedCredentials = replacingMatches(
            credentialProsePattern,
            in: sanitizedCookiePaths,
            withTemplate: "$1$2[REDACTED]"
        )
        return replacingMatches(
            bearerPattern,
            in: sanitizedCredentials,
            withTemplate: "$1$2[REDACTED]"
        )
    }

    static func sanitizedDiagnosticArguments(_ arguments: [String]) -> [String] {
        var sanitized: [String] = []
        var pendingFlag: String?

        for argument in arguments {
            if let flag = pendingFlag {
                sanitized.append(URLArgumentFlags.contains(flag) ? sanitizeURLString(argument) : "[REDACTED]")
                pendingFlag = nil
                continue
            }

            let flagAndValue = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let originalFlag = String(flagAndValue[0])
            let normalizedFlag = originalFlag.lowercased()
            let isSensitiveFlag = sensitiveArgumentFlags.contains(normalizedFlag)
                && (!normalizedFlag.hasPrefix("-") || normalizedFlag.hasPrefix("--") || originalFlag == normalizedFlag)
            if isSensitiveFlag || URLArgumentFlags.contains(normalizedFlag) {
                if flagAndValue.count == 2 {
                    let value = String(flagAndValue[1])
                    let replacement = URLArgumentFlags.contains(normalizedFlag) ? sanitizeURLString(value) : "[REDACTED]"
                    sanitized.append("\(flagAndValue[0])=\(replacement)")
                } else {
                    sanitized.append(argument)
                    pendingFlag = normalizedFlag
                }
                continue
            }

            if let shortFlag = ["-u", "-p", "-2"].first(where: {
                originalFlag.hasPrefix($0) && originalFlag.count > $0.count
            }) {
                sanitized.append("\(shortFlag)[REDACTED]")
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

    private static func sanitizeStructuredURLs(in detail: String) -> String {
        let range = NSRange(detail.startIndex..., in: detail)
        let matches = structuredURLPattern.matches(in: detail, range: range)
        guard !matches.isEmpty else { return detail }

        var result = detail
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let urlText = String(result[matchRange])
            result.replaceSubrange(matchRange, with: sanitizeURLString(urlText))
        }
        return result
    }

    private static func sanitizeURLString(_ value: String) -> String {
        let trailingPunctuation = value.reversed().prefix { ".,;)]}".contains($0) }
        let punctuation = String(trailingPunctuation.reversed())
        let urlText = String(value.dropLast(punctuation.count))
        guard var components = URLComponents(string: urlText), components.scheme != nil else {
            return "[REDACTED]"
        }
        components.user = nil
        components.password = nil
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { URLQueryItem(name: $0.name, value: "[REDACTED]") }
        }
        components.fragment = nil
        return (components.string ?? "[REDACTED]") + punctuation
    }

    private static func replacingMatches(
        _ pattern: NSRegularExpression,
        in value: String,
        withTemplate template: String
    ) -> String {
        pattern.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }
}
