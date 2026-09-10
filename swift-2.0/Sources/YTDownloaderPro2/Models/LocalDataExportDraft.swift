import Foundation

struct LocalDataExportDraft: Codable, Equatable, Sendable {
    enum ExportSection: String, Codable, Equatable, Sendable {
        case jobs
        case settings
        case thumbnails
        case diagnostics
    }

    struct Manifest: Codable, Equatable, Sendable {
        var appVersion: String
        var releaseChannel: String
        var exportDate: Date
        var schemaVersion: Int
        var selectedSections: [ExportSection]
    }

    struct ThumbnailReference: Codable, Equatable, Sendable {
        var jobID: UUID
        var cacheName: String
    }

    var manifest: Manifest
    var jobs: [DownloadJob]
    var settings: AppSettings
    var thumbnailReferences: [ThumbnailReference]
    var diagnosticExcerpt: [String]

    static func defaultPreview(
        appVersion: String,
        releaseChannel: String,
        exportDate: Date = Date(),
        jobs: [DownloadJob],
        settings: AppSettings,
        diagnosticLines: [String] = [],
        maximumDiagnosticLines: Int = 100
    ) -> LocalDataExportDraft {
        let exportedJobs = jobs.map(sanitizedJobForExport)
        return LocalDataExportDraft(
            manifest: Manifest(
                appVersion: appVersion,
                releaseChannel: releaseChannel,
                exportDate: exportDate,
                schemaVersion: 1,
                selectedSections: [.jobs, .settings, .thumbnails, .diagnostics]
            ),
            jobs: exportedJobs,
            settings: sanitizedSettingsForExport(settings),
            thumbnailReferences: thumbnailReferences(from: exportedJobs),
            diagnosticExcerpt: sanitizedDiagnosticExcerpt(
                from: diagnosticLines,
                maximumLines: maximumDiagnosticLines
            )
        )
    }

    private static func sanitizedJobForExport(_ job: DownloadJob) -> DownloadJob {
        var sanitized = job.scrubbingRetainedMediaURLCredentials()
        sanitized.outputURL = nil
        sanitized.options = sanitizedOptionsForExport(sanitized.options)
        return sanitized
    }

    private static func sanitizedSettingsForExport(_ settings: AppSettings) -> AppSettings {
        var sanitized = settings.clampedForPersistence()
        sanitized.defaultOptions = sanitizedOptionsForExport(sanitized.defaultOptions)
        return sanitized
    }

    private static func sanitizedOptionsForExport(_ options: DownloadOptions) -> DownloadOptions {
        var sanitized = options.normalizedForExecution()
        sanitized.cookies = .none
        sanitized.outputDirectoryBookmark = nil
        sanitized.outputDirectoryDisplayPath = nil
        return sanitized
    }

    private static func thumbnailReferences(from jobs: [DownloadJob]) -> [ThumbnailReference] {
        jobs.compactMap { job in
            guard let cachePath = job.thumbnailCachePath else { return nil }
            let cacheName = URL(fileURLWithPath: cachePath).lastPathComponent
            guard !cacheName.isEmpty else { return nil }
            return ThumbnailReference(jobID: job.id, cacheName: cacheName)
        }
    }

    private static func sanitizedDiagnosticExcerpt(
        from lines: [String],
        maximumLines: Int
    ) -> [String] {
        guard maximumLines > 0 else { return [] }
        let splitLines = lines.flatMap { line in
            line.split(whereSeparator: \.isNewline).map(String.init)
        }
        let sanitizedLines = splitLines.map { line in
            sanitizeExportDiagnosticLine(line)
        }
        let nonEmptyLines = sanitizedLines.filter { line in
            !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Array(nonEmptyLines.prefix(maximumLines))
    }

    private static func sanitizeExportDiagnosticLine(_ line: String) -> String {
        var sanitized = DownloadFailure.sanitizedDiagnosticDetail(line)
        sanitized = replacingMatches(structuredURLPattern, in: sanitized, withTemplate: "[REDACTED]")
        sanitized = replacingMatches(localPathPattern, in: sanitized, withTemplate: "[REDACTED]")
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
