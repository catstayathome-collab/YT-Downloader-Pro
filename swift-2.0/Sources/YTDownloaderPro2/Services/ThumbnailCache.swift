import Foundation

enum ThumbnailCacheError: Error, Equatable, Sendable {
    case invalidImageData
    case unsupportedImageType
    case unsupportedRemoteURL
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

    private let root: URL
    private let fileManager: FileManager
    private let loader: ThumbnailDataLoader

    init(root: URL, fileManager: FileManager = .default, loader: ThumbnailDataLoader = .live) {
        self.root = root
        self.fileManager = fileManager
        self.loader = loader
    }

    func store(data: Data, for jobID: UUID) throws -> URL {
        guard let imageType = Self.imageType(for: data) else {
            throw ThumbnailCacheError.invalidImageData
        }

        try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        try remove(jobID: jobID)
        let destination = thumbnailsDirectory.appendingPathComponent("\(jobID.uuidString).\(imageType.rawValue)")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func fetch(remoteURL: URL, for jobID: UUID) async throws -> URL {
        guard let scheme = remoteURL.scheme?.lowercased(), ["http", "https"].contains(scheme), remoteURL.host != nil else {
            throw ThumbnailCacheError.unsupportedRemoteURL
        }

        let download = try await loader.load(remoteURL)
        guard let mimeType = download.mimeType?.lowercased(), mimeType.hasPrefix("image/"),
              let imageType = Self.imageType(for: download.data), imageType.mimeTypes.contains(mimeType) else {
            throw ThumbnailCacheError.unsupportedImageType
        }
        return try store(data: download.data, for: jobID)
    }

    func url(for jobID: UUID) -> URL? {
        for imageType in ImageType.allCases {
            let candidate = thumbnailsDirectory.appendingPathComponent("\(jobID.uuidString).\(imageType.rawValue)")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    func remove(jobID: UUID) throws {
        for imageType in ImageType.allCases {
            let candidate = thumbnailsDirectory.appendingPathComponent("\(jobID.uuidString).\(imageType.rawValue)")
            if fileManager.fileExists(atPath: candidate.path) {
                try fileManager.removeItem(at: candidate)
            }
        }
    }

    private var thumbnailsDirectory: URL {
        root.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private static func imageType(for data: Data) -> ImageType? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return .png
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            return .gif
        }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.dropFirst(8).prefix(4) == Data("WEBP".utf8) {
            return .webp
        }
        return nil
    }
}
