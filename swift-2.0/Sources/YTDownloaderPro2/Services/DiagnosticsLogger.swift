import Foundation

struct DiagnosticEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let jobID: UUID?
    let stage: String
    let arguments: [String]
    let exitCode: Int32?
    let technicalDetail: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        jobID: UUID? = nil,
        stage: String,
        arguments: [String] = [],
        exitCode: Int32? = nil,
        technicalDetail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.jobID = jobID
        self.stage = stage
        self.arguments = DownloadFailure.sanitizedDiagnosticArguments(arguments)
        self.exitCode = exitCode
        self.technicalDetail = technicalDetail.map(DownloadFailure.sanitizedDiagnosticDetail)
    }

    func sanitized() -> DiagnosticEvent {
        DiagnosticEvent(
            id: id,
            timestamp: timestamp,
            jobID: jobID,
            stage: stage,
            arguments: arguments,
            exitCode: exitCode,
            technicalDetail: technicalDetail
        )
    }
}

protocol DiagnosticsFileSystem: Sendable {
    func validateMaintenanceDirectory(at url: URL) throws
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
}

extension DiagnosticsFileSystem {
    func validateMaintenanceDirectory(at url: URL) throws {}
}

struct LiveDiagnosticsFileSystem: DiagnosticsFileSystem {
    func validateMaintenanceDirectory(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func readData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true || values.isSymbolicLink == true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }
}

actor DiagnosticsLogger {
    static let maximumLogBytes = 5 * 1024 * 1024
    private static let rotatedLogCount = 3

    private enum RotationPhase: String, Codable {
        case cleanup
        case committing
        case preparing
    }

    private struct RotationMarker: Codable {
        let phase: RotationPhase
    }

    private let root: URL
    private let fileSystem: any DiagnosticsFileSystem
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL, fileSystem: any DiagnosticsFileSystem = LiveDiagnosticsFileSystem()) {
        self.root = root
        self.fileSystem = fileSystem
    }

    var currentLogURL: URL {
        logURL(generation: 0)
    }

    /// Point-in-time cleanup. Later download events may create a new log.
    func clear() throws {
        try fileSystem.validateMaintenanceDirectory(at: diagnosticsDirectory)
        // Remove recovery instructions first so a partial cleanup cannot restore old logs.
        let targets = [markerURL] + (0...Self.rotatedLogCount).map(backupURL) + logURLs
        for url in targets where fileSystem.fileExists(at: url) {
            try fileSystem.removeItem(at: url)
        }
    }

    /// Bounded, newest-first text for an explicit local export, never raw JSON or arguments.
    func exportLines(maximumLines: Int = 100) throws -> [String] {
        let limit = min(maximumLines, 100)
        guard limit > 0 else { return [] }
        try fileSystem.validateMaintenanceDirectory(at: diagnosticsDirectory)
        try recoverInterruptedRotation()
        var lines: [String] = []
        for url in logURLs {
            guard fileSystem.fileExists(at: url) else { continue }
            let data = try fileSystem.readData(at: url)
            for record in data.split(separator: 0x0A).reversed() {
                guard let event = try? decoder.decode(DiagnosticEvent.self, from: Data(record)) else { continue }
                let text = ([event.stage, event.exitCode.map { "exit=\($0)" } ?? "",
                             event.technicalDetail ?? ""] + event.arguments).joined(separator: " ")
                let sanitized = LocalDataExportDraft.sanitizeExportDiagnosticLine(text)
                    .split(whereSeparator: \.isNewline).joined(separator: " ")
                lines.append(String(sanitized.prefix(4096)))
                if lines.count == limit { return lines }
            }
        }
        return lines
    }

    func record(_ event: DiagnosticEvent) throws {
        try fileSystem.createDirectory(at: diagnosticsDirectory)
        try recoverInterruptedRotation()

        var line = try encoder.encode(event.sanitized())
        line.append(0x0A)

        let existingData: Data
        if fileSystem.fileExists(at: currentLogURL) {
            existingData = try fileSystem.readData(at: currentLogURL)
        } else {
            existingData = Data()
        }

        if !existingData.isEmpty, existingData.count + line.count > Self.maximumLogBytes {
            try rotate()
            try fileSystem.writeData(line, to: currentLogURL)
        } else {
            try fileSystem.writeData(existingData + line, to: currentLogURL)
        }
    }

    func details(for jobID: UUID) throws -> [DiagnosticEvent] {
        try recoverInterruptedRotation()
        var events: [DiagnosticEvent] = []
        for logURL in logURLs {
            guard fileSystem.fileExists(at: logURL) else { continue }
            let data = try fileSystem.readData(at: logURL)
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let event = try? decoder.decode(DiagnosticEvent.self, from: Data(line.utf8)), event.jobID == jobID else {
                    continue
                }
                events.append(event.sanitized())
            }
        }
        return events
    }

    func rotateIfNeeded() throws {
        try recoverInterruptedRotation()
        guard fileSystem.fileExists(at: currentLogURL) else { return }
        let currentData = try fileSystem.readData(at: currentLogURL)
        guard currentData.count >= Self.maximumLogBytes else { return }
        try rotate()
    }

    private var diagnosticsDirectory: URL {
        root.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var markerURL: URL {
        diagnosticsDirectory.appendingPathComponent("diagnostics.rotation.json")
    }

    private var logURLs: [URL] {
        (0...Self.rotatedLogCount).map(logURL)
    }

    private func logURL(generation: Int) -> URL {
        generation == 0
            ? diagnosticsDirectory.appendingPathComponent("diagnostics.jsonl")
            : diagnosticsDirectory.appendingPathComponent("diagnostics.\(generation).jsonl")
    }

    private func backupURL(generation: Int) -> URL {
        diagnosticsDirectory.appendingPathComponent("diagnostics.rotation-backup-\(generation).jsonl")
    }

    private func writeMarker(_ phase: RotationPhase) throws {
        try fileSystem.writeData(try encoder.encode(RotationMarker(phase: phase)), to: markerURL)
    }

    private func rotate() throws {
        try fileSystem.createDirectory(at: diagnosticsDirectory)
        try recoverInterruptedRotation()
        try writeMarker(.preparing)
        var phase = RotationPhase.preparing

        do {
            for generation in 0...Self.rotatedLogCount {
                let source = logURL(generation: generation)
                guard fileSystem.fileExists(at: source) else { continue }
                try fileSystem.moveItem(at: source, to: backupURL(generation: generation))
            }

            try writeMarker(.committing)
            phase = .committing
            for generation in 0..<Self.rotatedLogCount {
                let source = backupURL(generation: generation)
                guard fileSystem.fileExists(at: source) else { continue }
                try fileSystem.moveItem(at: source, to: logURL(generation: generation + 1))
            }

            try writeMarker(.cleanup)
            phase = .cleanup
            let droppedGeneration = backupURL(generation: Self.rotatedLogCount)
            if fileSystem.fileExists(at: droppedGeneration) {
                try fileSystem.removeItem(at: droppedGeneration)
            }
            try fileSystem.removeItem(at: markerURL)
        } catch {
            switch phase {
            case .preparing:
                try rollbackPreparingRotation()
                try removeMarkerIfPresent()
            case .committing:
                try rollbackCommittingRotation()
                try removeMarkerIfPresent()
            case .cleanup:
                break
            }
            throw error
        }
    }

    private func recoverInterruptedRotation() throws {
        guard fileSystem.fileExists(at: markerURL) else { return }
        let marker = try decoder.decode(RotationMarker.self, from: fileSystem.readData(at: markerURL))
        switch marker.phase {
        case .preparing:
            try rollbackPreparingRotation()
            try removeMarkerIfPresent()
        case .committing:
            try rollbackCommittingRotation()
            try removeMarkerIfPresent()
        case .cleanup:
            let droppedGeneration = backupURL(generation: Self.rotatedLogCount)
            if fileSystem.fileExists(at: droppedGeneration) {
                try fileSystem.removeItem(at: droppedGeneration)
            }
            try removeMarkerIfPresent()
        }
    }

    private func rollbackPreparingRotation() throws {
        for generation in stride(from: Self.rotatedLogCount, through: 0, by: -1) {
            let backup = backupURL(generation: generation)
            guard fileSystem.fileExists(at: backup) else { continue }
            let original = logURL(generation: generation)
            if fileSystem.fileExists(at: original) {
                try fileSystem.removeItem(at: original)
            }
            try fileSystem.moveItem(at: backup, to: original)
        }
    }

    private func rollbackCommittingRotation() throws {
        for generation in 0..<Self.rotatedLogCount {
            let backup = backupURL(generation: generation)
            guard !fileSystem.fileExists(at: backup) else { continue }
            let committed = logURL(generation: generation + 1)
            guard fileSystem.fileExists(at: committed) else { continue }
            try fileSystem.moveItem(at: committed, to: backup)
        }
        try rollbackPreparingRotation()
    }

    private func removeMarkerIfPresent() throws {
        if fileSystem.fileExists(at: markerURL) {
            try fileSystem.removeItem(at: markerURL)
        }
    }
}
