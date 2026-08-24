import Foundation

struct ProgressParser: Sendable {
    func parse(line: String) -> [DownloadEvent] {
        let filepathPrefix = "ytdp:filepath|"
        if line.hasPrefix(filepathPrefix) {
            let path = String(line.dropFirst(filepathPrefix.count))
            guard path.hasPrefix("/") else { return [] }
            return [.output(URL(fileURLWithPath: path))]
        }

        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let marker = fields.first else { return [] }

        switch marker {
        case "ytdp:progress":
            return parseProgress(fields: fields)
        case "ytdp:phase":
            guard fields.count == 2, let phase = DownloadPhase(rawValue: fields[1]) else { return [] }
            return [.phase(phase)]
        case "ytdp:completed":
            return fields.count == 1 ? [.completed] : []
        default:
            return []
        }
    }

    func parseDiagnostic(line: String) -> [DownloadEvent] {
        guard !line.isEmpty else { return [] }

        let structuredEvents = parse(line: line)
        if !structuredEvents.isEmpty {
            return structuredEvents
        }

        var events: [DownloadEvent] = []
        if line.hasPrefix("[Merger] Merging formats into ") {
            events.append(.phase(.merging))
        }
        events.append(.diagnostic(DownloadFailure.sanitizedTechnicalDetail(line)))
        return events
    }

    private func parseProgress(fields: [String]) -> [DownloadEvent] {
        guard fields.count == 6, let parsedPercent = percent(fields[1]) else { return [] }
        let fraction: Double?
        switch parsedPercent {
        case .missing:
            fraction = nil
        case let .value(value):
            fraction = value
        }

        return [
            .progress(
                JobProgress(
                    fraction: fraction,
                    downloadedBytes: nonnegativeInteger(fields[2]),
                    totalBytes: nonnegativeInteger(fields[3]),
                    bytesPerSecond: nonnegativeNumber(fields[4]),
                    etaSeconds: nonnegativeNumber(fields[5])
                )
            )
        ]
    }

    private func percent(_ field: String) -> Percent? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if isMissingNumericValue(trimmed) {
            return .missing
        }
        let valueText = trimmed.hasSuffix("%") ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        guard let value = Double(valueText), value.isFinite, value >= 0 else { return nil }
        return .value(min(value / 100, 1))
    }

    private func nonnegativeInteger(_ field: String) -> Int64? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isMissingNumericValue(trimmed), let value = Int64(trimmed), value >= 0 else {
            return nil
        }
        return value
    }

    private func nonnegativeNumber(_ field: String) -> Double? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isMissingNumericValue(trimmed), let value = Double(trimmed), value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    private func isMissingNumericValue(_ value: String) -> Bool {
        ["", "n/a", "na", "none", "null"].contains(value.lowercased())
    }

    private enum Percent {
        case missing
        case value(Double)
    }
}
