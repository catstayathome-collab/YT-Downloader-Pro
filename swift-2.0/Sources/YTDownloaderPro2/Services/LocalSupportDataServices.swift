import Foundation

enum LocalSupportDataServiceError: Error, Equatable, Sendable {
    case invalidDestination
    case destinationNotDirectory
    case mediaFileUnavailable
    case unsafeMediaSelection
}

struct LocalSupportReportWriter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(_ draft: SupportReportDraft, to directory: URL) throws -> URL {
        try validateDestinationDirectory(directory)
        let baseName = "YT-Downloader-Pro-Support-\(draft.incidentID.uuidString)"
        let destination = uniqueURL(in: directory, baseName: baseName, pathExtension: "json")
        let stagingURL = directory
            .appendingPathComponent(".ytdp-support-stage-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        try encoded(draft).write(to: stagingURL, options: .atomic)
        try fileManager.moveItem(at: stagingURL, to: destination)
        return destination
    }

    private func validateDestinationDirectory(_ directory: URL) throws {
        guard directory.isFileURL else {
            throw LocalSupportDataServiceError.invalidDestination
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalSupportDataServiceError.destinationNotDirectory
        }
    }

    private func uniqueURL(in directory: URL, baseName: String, pathExtension: String) -> URL {
        var suffix = 0
        while true {
            let suffixText = suffix == 0 ? "" : " (\(suffix))"
            let candidate = directory
                .appendingPathComponent(baseName + suffixText)
                .appendingPathExtension(pathExtension)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}

struct LocalExportPackageWriter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(_ draft: LocalDataExportDraft, to directory: URL) throws -> URL {
        try validateDestinationDirectory(directory)
        let identifier = UUID().uuidString
        let stagingURL = directory.appendingPathComponent(".ytdp-export-stage-\(identifier)", isDirectory: true)
        let packageURL = directory
            .appendingPathComponent("YT-Downloader-Pro-Export-\(identifier)", isDirectory: true)
            .appendingPathExtension("ytdpexport")
        var committed = false
        defer {
            if !committed, fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        try write(draft.manifest, named: "manifest.json", in: stagingURL)
        try write(draft.jobs, named: "jobs.json", in: stagingURL)
        try write(draft.settings, named: "settings.json", in: stagingURL)
        try write(draft.thumbnailReferences, named: "thumbnails.json", in: stagingURL)
        try write(draft.diagnosticExcerpt, named: "diagnostics.json", in: stagingURL)
        try fileManager.moveItem(at: stagingURL, to: packageURL)
        committed = true
        return packageURL
    }

    private func validateDestinationDirectory(_ directory: URL) throws {
        guard directory.isFileURL else {
            throw LocalSupportDataServiceError.invalidDestination
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalSupportDataServiceError.destinationNotDirectory
        }
    }

    private func write<Value: Encodable>(_ value: Value, named name: String, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(
            to: directory.appendingPathComponent(name),
            options: .atomic
        )
    }
}

struct SelectedMediaFileDeleter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func delete(_ selectedURL: URL) throws {
        guard selectedURL.isFileURL else {
            throw LocalSupportDataServiceError.unsafeMediaSelection
        }
        guard fileManager.fileExists(atPath: selectedURL.path) else {
            throw LocalSupportDataServiceError.mediaFileUnavailable
        }
        let values = try selectedURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isSymbolicLink != true else {
            throw LocalSupportDataServiceError.unsafeMediaSelection
        }
        try fileManager.removeItem(at: selectedURL)
    }
}
