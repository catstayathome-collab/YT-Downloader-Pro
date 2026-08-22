import Foundation

struct DownloadFailure: Error, Codable, Equatable, Sendable {
    enum Category: String, CaseIterable, Codable, Sendable {
        case invalidURL
        case metadataUnavailable
        case networkUnavailable
        case authenticationRequired
        case clientValidationFailed
        case formatReselectionRequired
        case unavailableMedia
        case bundledDownloaderUnavailable
        case bundledConverterUnavailable
        case outputPermissionDenied
        case diskFull
        case downloadFailed
        case postProcessingFailed
        case persistenceRecovery
        case unknown

        var summaryKey: String { "error.\(rawValue).summary" }
        var recoveryKey: String { "error.\(rawValue).recovery" }

        var supportsOptionsRecovery: Bool {
            switch self {
            case .authenticationRequired, .formatReselectionRequired, .outputPermissionDenied, .diskFull:
                true
            case .invalidURL, .metadataUnavailable, .networkUnavailable, .clientValidationFailed,
                 .unavailableMedia, .bundledDownloaderUnavailable, .bundledConverterUnavailable,
                 .downloadFailed, .postProcessingFailed, .persistenceRecovery, .unknown:
                false
            }
        }
    }

    enum Context: Sendable {
        case analysis
        case download
        case postProcessing
        case persistence
        case toolchain
    }

    var category: Category
    var summaryKey: String
    var recoverySuggestionKey: String?
    private(set) var technicalDetail: String?
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
    private static let attachedSensitiveShortFlagPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)(-[up2])\S+"#
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
        technicalDetail: String? = nil,
        toolExitCode: Int32? = nil,
        occurredAt: Date = .now
    ) {
        self.category = category
        self.summaryKey = category.summaryKey
        self.recoverySuggestionKey = category.recoveryKey
        self.technicalDetail = technicalDetail.map(Self.sanitizedDiagnosticDetail)
        self.toolExitCode = toolExitCode
        self.occurredAt = occurredAt
    }

    static func sanitizedTechnicalDetail(_ detail: String) -> String {
        sanitizedDiagnosticDetail(detail)
    }

    static func classify(
        stderr: String,
        context: Context = .download,
        exitCode: Int32? = nil
    ) -> DownloadFailure {
        let detail = stderr.lowercased()
        let category: Category
        let isSourceFailureContext = switch context {
        case .analysis, .download: true
        case .postProcessing, .persistence, .toolchain: false
        }

        if context == .toolchain {
            category = containsAny(detail, ["ffmpeg", "ffprobe", "converter"]) ? .bundledConverterUnavailable : .bundledDownloaderUnavailable
        } else if containsAny(detail, ["no space left on device", "disk full", "insufficient disk space"]) {
            category = .diskFull
        } else if containsAny(detail, ["operation not permitted", "permission denied", "read-only file system"])
                    || containsAccessDeniedDiagnostic(detail) {
            category = .outputPermissionDenied
        } else if isSourceFailureContext,
                  containsAny(detail, ["unsupported url", "invalid url", "not a valid url"]) {
            category = .invalidURL
        } else if isSourceFailureContext,
                  containsAny(detail, ["sign in to confirm", "login required", "age-restricted", "confirm your age", "members-only", "membership required"]) {
            category = .authenticationRequired
        } else if isSourceFailureContext,
                  containsAny(detail, ["private video", "video is private", "video unavailable", "video is unavailable", "removed by the uploader"])
                    || containsRegionRestrictionDiagnostic(detail) {
            category = .unavailableMedia
        } else if isSourceFailureContext,
                  containsAny(detail, [
            "network is unreachable", "network unreachable", "internet connection appears to be offline",
            "connection reset", "connection refused", "connection aborted", "timed out", "temporary failure in name resolution",
            "dns lookup failed", "name or service not known", "could not resolve host", "getaddrinfo failed",
            "certificate_verify_failed", "certificate verify failed"
        ]) {
            category = .networkUnavailable
        } else if isSourceFailureContext,
                  containsAny(detail, ["http error 403", "403 forbidden", "403: forbidden", "client validation", "player client validation"]) {
            category = .clientValidationFailed
        } else if isSourceFailureContext,
                  containsAny(detail, ["requested format is not available", "requested format not available", "selected format is no longer available", "format selection failed"]) {
            category = .formatReselectionRequired
        } else if containsAny(detail, ["bad cpu type", "not executable", "incompatible helper", "helper is unavailable", "is not installed"]) {
            category = containsAny(detail, ["ffmpeg", "ffprobe", "converter"]) ? .bundledConverterUnavailable : .bundledDownloaderUnavailable
        } else {
            category = switch context {
            case .analysis: .metadataUnavailable
            case .download: .downloadFailed
            case .postProcessing: .postProcessingFailed
            case .persistence: .persistenceRecovery
            case .toolchain: .bundledDownloaderUnavailable
            }
        }

        return DownloadFailure(
            category: category,
            technicalDetail: stderr,
            toolExitCode: exitCode
        )
    }

    func userSummary(locale: String) -> String {
        L10n.string(summaryKey, localeIdentifier: locale)
    }

    func userRecoverySuggestion(locale: String) -> String {
        L10n.string(recoverySuggestionKey ?? category.recoveryKey, localeIdentifier: locale)
    }

    static func sanitizedDiagnosticDetail(_ detail: String) -> String {
        let sanitizedURLs = sanitizeStructuredURLs(in: sanitizeBasic(detail))
        let sanitizedFlags = replacingMatches(
            sensitiveFlagInTextPattern,
            in: sanitizedURLs,
            withTemplate: "$1[REDACTED]"
        )
        let sanitizedAttachedFlags = replacingMatches(
            attachedSensitiveShortFlagPattern,
            in: sanitizedFlags,
            withTemplate: "$1[REDACTED]"
        )
        let sanitizedCookiePaths = replacingMatches(
            cookiePathPattern,
            in: sanitizedAttachedFlags,
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

    private static func sanitizeBasic(_ detail: String) -> String {
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

    private enum CodingKeys: String, CodingKey {
        case category
        case summaryKey
        case recoverySuggestionKey
        case technicalDetail
        case toolExitCode
        case occurredAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let category = try container.decode(Category.self, forKey: .category)
        self.init(
            category: category,
            technicalDetail: try container.decodeIfPresent(String.self, forKey: .technicalDetail),
            toolExitCode: try container.decodeIfPresent(Int32.self, forKey: .toolExitCode),
            occurredAt: try container.decodeIfPresent(Date.self, forKey: .occurredAt) ?? .now
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

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains(where: value.contains)
    }

    private static func containsAccessDeniedDiagnostic(_ detail: String) -> Bool {
        detail.split(whereSeparator: \Character.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let message = line.hasPrefix("error:")
                ? line.dropFirst("error:".count).trimmingCharacters(in: .whitespaces)
                : line
            return ["access denied", "access is denied"].contains { phrase in
                message == phrase || message.hasPrefix("\(phrase) while ")
            }
        }
    }

    private static func containsRegionRestrictionDiagnostic(_ detail: String) -> Bool {
        let exactMessages: Set<String> = [
            "video is region restricted",
            "this video is restricted in your region",
            "the uploader has not made this video available in your country",
            "this video is not available in your country",
            "this video is geo-restricted"
        ]

        return detail.split(whereSeparator: \Character.isNewline).contains { rawLine in
            var message = rawLine.trimmingCharacters(in: .whitespaces)
            guard message.hasPrefix("error:") else { return false }
            message = message.dropFirst("error:".count).trimmingCharacters(in: .whitespaces)

            if message.hasPrefix("[") {
                guard let extractorMessage = messageAfterMaintainedExtractorPrefix(message) else {
                    return false
                }
                message = extractorMessage
            }

            while let last = message.last, ".!?".contains(last) {
                message.removeLast()
            }
            return exactMessages.contains(message)
        }
    }

    private static func messageAfterMaintainedExtractorPrefix(_ message: String) -> String? {
        let prefixes = ["[youtube]", "[youtube:tab]"]
        guard let prefix = prefixes.first(where: message.hasPrefix) else { return nil }

        var remainder = message.dropFirst(prefix.count)
        guard remainder.first?.isWhitespace == true else { return nil }
        remainder = remainder.drop(while: \Character.isWhitespace)

        guard let separator = remainder.firstIndex(of: ":") else { return nil }
        let identifier = remainder[..<separator]
        guard isValidExtractorIdentifier(identifier) else { return nil }

        return remainder[remainder.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isValidExtractorIdentifier(_ identifier: Substring) -> Bool {
        !identifier.isEmpty && identifier.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }
}
