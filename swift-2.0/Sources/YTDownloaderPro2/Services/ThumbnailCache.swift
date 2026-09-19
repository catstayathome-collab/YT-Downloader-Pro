import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ThumbnailCacheError: Error, Equatable, Sendable {
    case invalidImageData
    case unsupportedImageType
    case unsupportedRemoteURL
    case unsafeCachePath
}

struct ThumbnailDownload: Sendable {
    let data: Data
    let mimeType: String?
}

struct ThumbnailDataLoader: Sendable {
    let load: @Sendable (URL) async throws -> ThumbnailDownload

    init(_ load: @escaping @Sendable (URL) async throws -> ThumbnailDownload) {
        self.load = load
    }

    static let live = ThumbnailDataLoader { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        let mimeType = (response as? HTTPURLResponse)?.mimeType
        return ThumbnailDownload(data: data, mimeType: mimeType)
    }
}

protocol ThumbnailFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func replaceItem(at originalURL: URL, withItemAt newURL: URL, backupItemName: String) throws -> URL?
    func removeItem(at url: URL) throws
    func isSymbolicLink(at url: URL) throws -> Bool
}

struct LiveThumbnailFileSystem: ThumbnailFileSystem {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL, backupItemName: String) throws -> URL? {
        try FileManager.default.replaceItemAt(
            originalURL,
            withItemAt: newURL,
            backupItemName: backupItemName,
            options: .withoutDeletingBackupItem
        )
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func isSymbolicLink(at url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }
}

actor ThumbnailCache {
    private enum ImageType: String, CaseIterable {
        case gif
        case jpeg = "jpg"
        case png
        case webp

        var mimeTypes: Set<String> {
            switch self {
            case .gif:
                ["image/gif"]
            case .jpeg:
                ["image/jpeg", "image/jpg", "image/pjpeg"]
            case .png:
                ["image/png"]
            case .webp:
                ["image/webp"]
            }
        }
    }

    private let configuredRoot: URL
    private let canonicalRoot: URL
    private let fileSystem: any ThumbnailFileSystem
    private let loader: ThumbnailDataLoader

    init(
        root: URL,
        fileSystem: any ThumbnailFileSystem = LiveThumbnailFileSystem(),
        loader: ThumbnailDataLoader = .live
    ) {
        configuredRoot = root.standardizedFileURL
        canonicalRoot = configuredRoot.resolvingSymlinksInPath().standardizedFileURL
        self.fileSystem = fileSystem
        self.loader = loader
    }

    func store(data: Data, for jobID: UUID) throws -> URL {
        guard let imageType = Self.imageType(for: data) else {
            throw ThumbnailCacheError.invalidImageData
        }

        let directory = try validatedThumbnailsDirectory(createIfMissing: true)
        let existing = try existingThumbnails(for: jobID, in: directory)
        let snapshots = try Dictionary(uniqueKeysWithValues: existing.map { ($0, try fileSystem.readData(at: $0)) })
        let destination = thumbnailURL(for: jobID, type: imageType, in: directory)
        let transactionID = UUID().uuidString
        let temporaryURL = directory.appendingPathComponent(".thumbnail-stage-\(transactionID).\(imageType.rawValue)")
        let backupName = ".thumbnail-backup-\(transactionID).\(imageType.rawValue)"
        let backupURL = directory.appendingPathComponent(backupName)
        let destinationExisted = existing.contains(destination)
        var installationAttempted = false

        do {
            try validateMutationTarget(temporaryURL, in: directory, mustNotExist: true)
            try fileSystem.writeData(data, to: temporaryURL)
            try validateMutationTarget(temporaryURL, in: directory, mustNotExist: false)
            let stagedData = try fileSystem.readData(at: temporaryURL)
            guard Self.imageType(for: stagedData) == imageType else {
                throw ThumbnailCacheError.invalidImageData
            }

            try recheckDirectory(directory)
            try validateMutationTarget(destination, in: directory, mustNotExist: false)
            installationAttempted = true
            if fileSystem.fileExists(at: destination) {
                _ = try fileSystem.replaceItem(at: destination, withItemAt: temporaryURL, backupItemName: backupName)
            } else {
                try fileSystem.moveItem(at: temporaryURL, to: destination)
            }
            try validateMutationTarget(destination, in: directory, mustNotExist: false)

            for obsoleteURL in existing where obsoleteURL != destination {
                try validateMutationTarget(obsoleteURL, in: directory, mustNotExist: false)
                try fileSystem.removeItem(at: obsoleteURL)
            }
            if fileSystem.fileExists(at: backupURL) {
                try validateMutationTarget(backupURL, in: directory, mustNotExist: false)
                try fileSystem.removeItem(at: backupURL)
            }
            return destination
        } catch let operationError {
            if installationAttempted {
                do {
                    try rollbackInstallation(
                        snapshots: snapshots,
                        destination: destination,
                        destinationExisted: destinationExisted,
                        backupURL: backupURL,
                        in: directory
                    )
                } catch {
                    throw error
                }
            }
            if fileSystem.fileExists(at: temporaryURL), (try? fileSystem.isSymbolicLink(at: temporaryURL)) != true {
                try? fileSystem.removeItem(at: temporaryURL)
            }
            throw operationError
        }
    }

    func fetch(remoteURL: URL, for jobID: UUID) async throws -> URL {
        let download = try await download(remoteURL: remoteURL)
        return try install(download, for: jobID)
    }

    func download(remoteURL: URL) async throws -> ThumbnailDownload {
        guard let components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw ThumbnailCacheError.unsupportedRemoteURL
        }

        let download = try await loader.load(remoteURL)
        guard let mimeType = download.mimeType?.lowercased(), mimeType.hasPrefix("image/"),
              let imageType = Self.imageType(for: download.data), imageType.mimeTypes.contains(mimeType) else {
            throw ThumbnailCacheError.unsupportedImageType
        }
        return download
    }

    func install(_ download: ThumbnailDownload, for jobID: UUID) throws -> URL {
        guard let mimeType = download.mimeType?.lowercased(), mimeType.hasPrefix("image/"),
              let imageType = Self.imageType(for: download.data), imageType.mimeTypes.contains(mimeType) else {
            throw ThumbnailCacheError.unsupportedImageType
        }
        return try store(data: download.data, for: jobID)
    }

    func url(for jobID: UUID) -> URL? {
        guard let directory = try? validatedThumbnailsDirectory(createIfMissing: false),
              let thumbnails = try? existingThumbnails(for: jobID, in: directory) else {
            return nil
        }
        return thumbnails.first
    }

    func remove(jobID: UUID) throws {
        let directory = try validatedThumbnailsDirectory(createIfMissing: false)
        for candidate in try existingThumbnails(for: jobID, in: directory) {
            try recheckDirectory(directory)
            try validateMutationTarget(candidate, in: directory, mustNotExist: false)
            try fileSystem.removeItem(at: candidate)
        }
    }

    private func rollbackInstallation(
        snapshots: [URL: Data],
        destination: URL,
        destinationExisted: Bool,
        backupURL: URL,
        in directory: URL
    ) throws {
        try recheckDirectory(directory)

        if fileSystem.fileExists(at: backupURL) {
            try validateMutationTarget(backupURL, in: directory, mustNotExist: false)
            if fileSystem.fileExists(at: destination) {
                try validateMutationTarget(destination, in: directory, mustNotExist: false)
                try fileSystem.removeItem(at: destination)
            }
            try recheckDirectory(directory)
            try validateMutationTarget(destination, in: directory, mustNotExist: true)
            try fileSystem.moveItem(at: backupURL, to: destination)
        } else if !destinationExisted, fileSystem.fileExists(at: destination) {
            try validateMutationTarget(destination, in: directory, mustNotExist: false)
            try fileSystem.removeItem(at: destination)
        }

        for (url, data) in snapshots {
            guard !fileSystem.fileExists(at: url) else { continue }
            try recheckDirectory(directory)
            try validateMutationTarget(url, in: directory, mustNotExist: true)
            try fileSystem.writeData(data, to: url)
        }
    }

    private func validatedThumbnailsDirectory(createIfMissing: Bool) throws -> URL {
        try validateConfiguredRoot()
        let directory = canonicalRoot.appendingPathComponent("Thumbnails", isDirectory: true).standardizedFileURL
        guard contains(directory, in: canonicalRoot) else {
            throw ThumbnailCacheError.unsafeCachePath
        }
        if (try? fileSystem.isSymbolicLink(at: directory)) == true {
            throw ThumbnailCacheError.unsafeCachePath
        }
        if !fileSystem.fileExists(at: directory) {
            guard createIfMissing else { return directory }
            try fileSystem.createDirectory(at: directory)
        }
        try recheckDirectory(directory)
        return directory
    }

    private func recheckDirectory(_ directory: URL) throws {
        try validateConfiguredRoot()
        guard contains(directory, in: canonicalRoot),
              directory.resolvingSymlinksInPath().standardizedFileURL == directory,
              (try? fileSystem.isSymbolicLink(at: directory)) != true else {
            throw ThumbnailCacheError.unsafeCachePath
        }
    }

    private func validateConfiguredRoot() throws {
        guard configuredRoot == canonicalRoot,
              configuredRoot.resolvingSymlinksInPath().standardizedFileURL == canonicalRoot else {
            throw ThumbnailCacheError.unsafeCachePath
        }
        if fileSystem.fileExists(at: configuredRoot), try fileSystem.isSymbolicLink(at: configuredRoot) {
            throw ThumbnailCacheError.unsafeCachePath
        }
    }

    private func existingThumbnails(for jobID: UUID, in directory: URL) throws -> [URL] {
        guard fileSystem.fileExists(at: directory) else { return [] }
        try recheckDirectory(directory)
        var existing: [URL] = []
        for imageType in ImageType.allCases {
            let candidate = thumbnailURL(for: jobID, type: imageType, in: directory)
            if (try? fileSystem.isSymbolicLink(at: candidate)) == true {
                throw ThumbnailCacheError.unsafeCachePath
            }
            guard fileSystem.fileExists(at: candidate) else { continue }
            try validateMutationTarget(candidate, in: directory, mustNotExist: false)
            existing.append(candidate)
        }
        return existing
    }

    private func validateMutationTarget(_ url: URL, in directory: URL, mustNotExist: Bool) throws {
        try recheckDirectory(directory)
        guard url.standardizedFileURL.deletingLastPathComponent() == directory,
              contains(url.standardizedFileURL, in: canonicalRoot),
              (try? fileSystem.isSymbolicLink(at: url)) != true,
              !mustNotExist || !fileSystem.fileExists(at: url) else {
            throw ThumbnailCacheError.unsafeCachePath
        }
        if fileSystem.fileExists(at: url), url.resolvingSymlinksInPath().standardizedFileURL != url.standardizedFileURL {
            throw ThumbnailCacheError.unsafeCachePath
        }
    }

    private func thumbnailURL(for jobID: UUID, type: ImageType, in directory: URL) -> URL {
        directory.appendingPathComponent("\(jobID.uuidString).\(type.rawValue)")
    }

    private func contains(_ child: URL, in root: URL) -> Bool {
        child.path == root.path || child.path.hasPrefix(root.path + "/")
    }

    private static func imageType(for data: Data) -> ImageType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let sourceType = CGImageSourceGetType(source) else {
            return nil
        }

        let type = UTType(sourceType as String)
        if type == .png { return .png }
        if type == .jpeg { return .jpeg }
        if type == .gif { return .gif }
        if type == .webP { return .webp }
        return nil
    }
}
