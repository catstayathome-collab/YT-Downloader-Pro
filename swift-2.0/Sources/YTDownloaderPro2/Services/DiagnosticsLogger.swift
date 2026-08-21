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

actor DiagnosticsLogger {
    static let maximumLogBytes = 5 * 1024 * 1024
    private static let rotatedLogCount = 3

    private let root: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    var currentLogURL: URL {
        diagnosticsDirectory.appendingPathComponent("diagnostics.jsonl")
    }

    func record(_ event: DiagnosticEvent) throws {
        try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        var line = try encoder.encode(event.sanitized())
        line.append(0x0A)

        let existingData = (try? Data(contentsOf: currentLogURL)) ?? Data()
        if existingData.count + line.count > Self.maximumLogBytes {
            try rotateIfNeeded(force: true)
        }

        let updatedData = ((try? Data(contentsOf: currentLogURL)) ?? Data()) + line
        try updatedData.write(to: currentLogURL, options: .atomic)
    }

    func details(for jobID: UUID) throws -> [DiagnosticEvent] {
        var events: [DiagnosticEvent] = []
        for logURL in logURLs {
            guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else {
                continue
            }
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
        guard let attributes = try? fileManager.attributesOfItem(atPath: currentLogURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= Self.maximumLogBytes else {
            return
        }
        try rotateIfNeeded(force: true)
    }

    private var diagnosticsDirectory: URL {
        root.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var logURLs: [URL] {
        [currentLogURL] + (1...Self.rotatedLogCount).map(rotatedLogURL)
    }

    private func rotatedLogURL(_ index: Int) -> URL {
        diagnosticsDirectory.appendingPathComponent("diagnostics.\(index).jsonl")
    }

    private func rotateIfNeeded(force: Bool) throws {
        guard force, fileManager.fileExists(atPath: currentLogURL.path) else { return }
        try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let oldestURL = rotatedLogURL(Self.rotatedLogCount)
        if fileManager.fileExists(atPath: oldestURL.path) {
            try fileManager.removeItem(at: oldestURL)
        }
        for index in stride(from: Self.rotatedLogCount - 1, through: 1, by: -1) {
            let source = rotatedLogURL(index)
            let destination = rotatedLogURL(index + 1)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        try fileManager.moveItem(at: currentLogURL, to: rotatedLogURL(1))
    }
}
