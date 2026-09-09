import Foundation

struct SupportReportDraft: Codable, Equatable, Sendable {
    enum Category: String, Codable, Equatable, Sendable {
        case downloadFailure
        case privacy
        case security
        case copyright
        case cancellation
        case incorrectCharge
        case accountRecovery
        case general

        var bypassesPaidPriorityRules: Bool {
            switch self {
            case .privacy, .security, .copyright, .cancellation, .incorrectCharge, .accountRecovery:
                true
            case .downloadFailure, .general:
                false
            }
        }
    }

    struct Environment: Codable, Equatable, Sendable {
        var appVersion: String
        var releaseChannel: String
        var macOSVersion: String
        var architecture: String
        var localeIdentifier: String
    }

    struct FailureContext: Codable, Equatable, Sendable {
        var jobID: UUID?
        var category: DownloadFailure.Category
        var recoverySuggestionKey: String?
        var toolExitCode: Int32?
    }

    struct OptionalFields: Codable, Equatable, Sendable {
        var sourceURL: String?
        var mediaTitle: String?
        var selectedFormatID: String?
        var diagnosticExportName: String?
        var screenshotName: String?
        var contactEmail: String?
        var mediaFileName: String?

        static let disabled = OptionalFields()
    }

    var category: Category
    var subject: String
    var message: String
    var environment: Environment
    var incidentID: UUID
    var failure: FailureContext?
    var diagnosticExcerpt: [String]
    var optionalFields: OptionalFields
    var bypassesPaidPriorityRules: Bool

    static func defaultPreview(
        category: Category,
        subject: String,
        message: String,
        environment: Environment,
        incidentID: UUID = UUID(),
        selectedJob: DownloadJob? = nil,
        selectedFailure: DownloadFailure? = nil,
        diagnosticLines: [String] = [],
        maximumDiagnosticLines: Int = 20
    ) -> SupportReportDraft {
        let failure = selectedFailure.map {
            FailureContext(
                jobID: selectedJob?.id,
                category: $0.category,
                recoverySuggestionKey: $0.recoverySuggestionKey,
                toolExitCode: $0.toolExitCode
            )
        }
        let failureDetail = selectedFailure?.technicalDetail.map { [$0] } ?? []
        let excludedPhrases = [selectedJob?.title].compactMap { $0 }

        return SupportReportDraft(
            category: category,
            subject: subject,
            message: message,
            environment: environment,
            incidentID: incidentID,
            failure: failure,
            diagnosticExcerpt: sanitizedDiagnosticExcerpt(
                from: failureDetail + diagnosticLines,
                excluding: excludedPhrases,
                maximumLines: maximumDiagnosticLines
            ),
            optionalFields: .disabled,
            bypassesPaidPriorityRules: category.bypassesPaidPriorityRules
        )
    }

    private static func sanitizedDiagnosticExcerpt(
        from lines: [String],
        excluding phrases: [String],
        maximumLines: Int
    ) -> [String] {
        guard maximumLines > 0 else { return [] }
        let splitLines = lines.flatMap { line in
            line.split(whereSeparator: \.isNewline).map(String.init)
        }
        let sanitizedLines = splitLines.map { line in
            sanitizeSupportDiagnosticLine(line, excluding: phrases)
        }
        let nonEmptyLines = sanitizedLines.filter { line in
            !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Array(nonEmptyLines.prefix(maximumLines))
    }

    private static func sanitizeSupportDiagnosticLine(_ line: String, excluding phrases: [String]) -> String {
        var sanitized = DownloadFailure.sanitizedDiagnosticDetail(line)
        sanitized = replacingMatches(structuredURLPattern, in: sanitized, withTemplate: "[REDACTED]")
        sanitized = replacingMatches(localPathPattern, in: sanitized, withTemplate: "[REDACTED]")
        for phrase in phrases where !phrase.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: phrase, with: "[REDACTED]")
        }
        return sanitized
    }

    private static let structuredURLPattern = try! NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s\"'<>]+"#
    )

    private static let localPathPattern = try! NSRegularExpression(
        pattern: #"(?:(?:~|/)[^\r\n,;]*)"#
    )

    private static func replacingMatches(
        _ regex: NSRegularExpression,
        in value: String,
        withTemplate template: String
    ) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
