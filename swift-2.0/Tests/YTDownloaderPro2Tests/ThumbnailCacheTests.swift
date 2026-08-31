import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import YTDownloaderPro2

final class ThumbnailCacheTests: XCTestCase {
    func testStoreNamesThumbnailWithJobIDAndDetectedImageExtension() async throws {
        let cache = ThumbnailCache(root: try temporaryDirectory())
        let jobID = UUID()

        let storedURL = try await cache.store(data: pngData, for: jobID)
        let cachedURL = await cache.url(for: jobID)

        XCTAssertEqual(storedURL.lastPathComponent, "\(jobID.uuidString).png")
        XCTAssertEqual(try Data(contentsOf: storedURL), pngData)
        XCTAssertEqual(cachedURL, storedURL)
    }

    func testStoreRejectsDataThatIsNotAnImage() async throws {
        let cache = ThumbnailCache(root: try temporaryDirectory())

        do {
            _ = try await cache.store(data: Data("not an image".utf8), for: UUID())
            XCTFail("Expected invalid thumbnail data to be rejected")
        } catch let error as ThumbnailCacheError {
            XCTAssertEqual(error, .invalidImageData)
        }
    }

    func testStoreRejectsTruncatedOrSignatureSpoofedSupportedImages() async throws {
        let cache = ThumbnailCache(root: try temporaryDirectory())
        let malformedImages: [Data] = [
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]),
            Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]),
            Data("GIF89a-not-an-image".utf8),
            Data("RIFF\0\0\0\0WEBP-not-an-image".utf8)
        ]

        for data in malformedImages {
            do {
                _ = try await cache.store(data: data, for: UUID())
                XCTFail("Expected malformed image data to be rejected")
            } catch let error as ThumbnailCacheError {
                XCTAssertEqual(error, .invalidImageData)
            }
        }
    }

    func testRemovingRecordDeletesOnlyItsCachedThumbnail() async throws {
        let cache = ThumbnailCache(root: try temporaryDirectory())
        let first = UUID()
        let second = UUID()
        _ = try await cache.store(data: pngData, for: first)
        let secondURL = try await cache.store(data: jpegData, for: second)

        try await cache.remove(jobID: first)
        let firstURL = await cache.url(for: first)
        let remainingURL = await cache.url(for: second)

        XCTAssertNil(firstURL)
        XCTAssertEqual(remainingURL, secondURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testFailedCrossExtensionReplacementPreservesPriorThumbnail() async throws {
        for fault in [ThumbnailFileFault.write, .read, .move, .remove] {
            let root = try temporaryDirectory()
            let jobID = UUID()
            let initialCache = ThumbnailCache(root: root)
            let originalURL = try await initialCache.store(data: pngData, for: jobID)
            let cache = ThumbnailCache(root: root, fileSystem: ThumbnailFaultFileSystem(failingOnce: fault))

            do {
                _ = try await cache.store(data: jpegData, for: jobID)
                XCTFail("Expected \(fault) to fail replacement")
            } catch {
                XCTAssertEqual(try Data(contentsOf: originalURL), pngData)
                let cachedURL = await initialCache.url(for: jobID)
                XCTAssertEqual(cachedURL, originalURL)
            }
        }
    }

    func testFailedSameExtensionAtomicInstallPreservesPriorThumbnail() async throws {
        let root = try temporaryDirectory()
        let jobID = UUID()
        let initialCache = ThumbnailCache(root: root)
        let originalURL = try await initialCache.store(data: jpegData, for: jobID)
        let cache = ThumbnailCache(root: root, fileSystem: ThumbnailFaultFileSystem(failingOnce: .replace))

        do {
            _ = try await cache.store(data: replacementJPEGData, for: jobID)
            XCTFail("Expected atomic replacement to fail")
        } catch {
            XCTAssertEqual(try Data(contentsOf: originalURL), jpegData)
            let cachedURL = await initialCache.url(for: jobID)
            XCTAssertEqual(cachedURL, originalURL)
        }
    }

    func testPostMutationMoveFailurePreservesPriorExtensionAndLookup() async throws {
        let root = try temporaryDirectory()
        let jobID = UUID()
        let initialCache = ThumbnailCache(root: root)
        let originalURL = try await initialCache.store(data: pngData, for: jobID)
        let originalFileNumber = try fileNumber(at: originalURL)
        let replacementURL = originalURL.deletingPathExtension().appendingPathExtension("jpg")
        let cache = ThumbnailCache(
            root: root,
            fileSystem: ThumbnailFaultFileSystem(failingOnce: .moveAfterMutation)
        )

        do {
            _ = try await cache.store(data: jpegData, for: jobID)
            XCTFail("Expected post-mutation move failure")
        } catch {
            let cachedURL = await initialCache.url(for: jobID)
            XCTAssertEqual(try Data(contentsOf: originalURL), pngData)
            XCTAssertEqual(try fileNumber(at: originalURL), originalFileNumber)
            XCTAssertEqual(cachedURL, originalURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: replacementURL.path))
            XCTAssertEqual(try thumbnailFileNames(in: root), [originalURL.lastPathComponent])
        }
    }

    func testPostMutationReplaceFailureRestoresExactPriorThumbnail() async throws {
        let root = try temporaryDirectory()
        let jobID = UUID()
        let initialCache = ThumbnailCache(root: root)
        let originalURL = try await initialCache.store(data: jpegData, for: jobID)
        let originalFileNumber = try fileNumber(at: originalURL)
        let cache = ThumbnailCache(
            root: root,
            fileSystem: ThumbnailFaultFileSystem(failingOnce: .replaceAfterMutation)
        )

        do {
            _ = try await cache.store(data: replacementJPEGData, for: jobID)
            XCTFail("Expected post-mutation replace failure")
        } catch {
            let cachedURL = await initialCache.url(for: jobID)
            XCTAssertEqual(try Data(contentsOf: originalURL), jpegData)
            XCTAssertEqual(cachedURL, originalURL)
            XCTAssertEqual(try fileNumber(at: originalURL), originalFileNumber)
            XCTAssertEqual(try thumbnailFileNames(in: root), [originalURL.lastPathComponent])
        }
    }

    func testDirectorySymlinkIsRejectedForStoreLookupAndRemoval() async throws {
        let lookup = try makeDirectorySymlinkFixture()
        let lookupURL = await lookup.cache.url(for: lookup.jobID)
        XCTAssertNil(lookupURL)
        XCTAssertEqual(try Data(contentsOf: lookup.outsideFile), pngData)

        let store = try makeDirectorySymlinkFixture()
        await assertUnsafeCachePath {
            _ = try await store.cache.store(data: jpegData, for: store.jobID)
        }
        XCTAssertEqual(try Data(contentsOf: store.outsideFile), pngData)

        let removal = try makeDirectorySymlinkFixture()
        await assertUnsafeCachePath {
            try await removal.cache.remove(jobID: removal.jobID)
        }
        XCTAssertEqual(try Data(contentsOf: removal.outsideFile), pngData)
    }

    func testLeafSymlinkIsRejectedForStoreLookupAndRemoval() async throws {
        let lookup = try makeLeafSymlinkFixture()
        let lookupURL = await lookup.cache.url(for: lookup.jobID)
        XCTAssertNil(lookupURL)
        XCTAssertEqual(try Data(contentsOf: lookup.outsideFile), pngData)

        let store = try makeLeafSymlinkFixture()
        await assertUnsafeCachePath {
            _ = try await store.cache.store(data: pngData, for: store.jobID)
        }
        XCTAssertEqual(try Data(contentsOf: store.outsideFile), pngData)

        let removal = try makeLeafSymlinkFixture()
        await assertUnsafeCachePath {
            try await removal.cache.remove(jobID: removal.jobID)
        }
        XCTAssertEqual(try Data(contentsOf: removal.outsideFile), pngData)
    }

    func testStoreRejectsConfiguredRootSymlink() async throws {
        let fixture = try makeRootSymlinkFixture()

        await assertUnsafeCachePath {
            _ = try await fixture.cache.store(data: jpegData, for: fixture.jobID)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.outsideFile), pngData)
    }

    func testLookupRejectsConfiguredRootSymlink() async throws {
        let fixture = try makeRootSymlinkFixture()
        let cachedURL = await fixture.cache.url(for: fixture.jobID)

        XCTAssertNil(cachedURL)
        XCTAssertEqual(try Data(contentsOf: fixture.outsideFile), pngData)
    }

    func testRemovalRejectsConfiguredRootSymlink() async throws {
        let fixture = try makeRootSymlinkFixture()

        await assertUnsafeCachePath {
            try await fixture.cache.remove(jobID: fixture.jobID)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.outsideFile), pngData)
    }

    func testFetchRejectsNonHTTPURLWithoutCallingInjectedLoader() async throws {
        let recorder = ThumbnailRequestRecorder()
        let loader = ThumbnailDataLoader { url in
            await recorder.record(url)
            return ThumbnailDownload(data: pngData, mimeType: "image/png")
        }
        let cache = ThumbnailCache(root: try temporaryDirectory(), loader: loader)

        do {
            _ = try await cache.fetch(remoteURL: try XCTUnwrap(URL(string: "file:///private/secret.png")), for: UUID())
            XCTFail("Expected a non-HTTP(S) thumbnail URL to be rejected")
        } catch let error as ThumbnailCacheError {
            XCTAssertEqual(error, .unsupportedRemoteURL)
        }
        let requestedURLs = await recorder.urls
        XCTAssertEqual(requestedURLs, [])
    }

    func testFetchRejectsCredentialBearingURLWithoutCallingInjectedLoader() async throws {
        let recorder = ThumbnailRequestRecorder()
        let loader = ThumbnailDataLoader { url in
            await recorder.record(url)
            return ThumbnailDownload(data: pngData, mimeType: "image/png")
        }
        let cache = ThumbnailCache(root: try temporaryDirectory(), loader: loader)

        do {
            _ = try await cache.fetch(
                remoteURL: try XCTUnwrap(URL(string: "https://thumb-user:thumb-secret@images.example.test/thumbnail.png")),
                for: UUID()
            )
            XCTFail("Expected a credential-bearing thumbnail URL to be rejected")
        } catch let error as ThumbnailCacheError {
            XCTAssertEqual(error, .unsupportedRemoteURL)
        }
        let requestedURLs = await recorder.urls
        XCTAssertEqual(requestedURLs, [])
    }

    func testFetchUsesValidatedImageTypeForStoredExtension() async throws {
        let recorder = ThumbnailRequestRecorder()
        let loader = ThumbnailDataLoader { url in
            await recorder.record(url)
            return ThumbnailDownload(data: jpegData, mimeType: "image/jpeg")
        }
        let cache = ThumbnailCache(root: try temporaryDirectory(), loader: loader)
        let remoteURL = try XCTUnwrap(URL(string: "https://images.example.test/thumbnail.png"))

        let storedURL = try await cache.fetch(remoteURL: remoteURL, for: UUID())
        let requestedURLs = await recorder.urls

        XCTAssertEqual(storedURL.pathExtension, "jpg")
        XCTAssertEqual(requestedURLs, [remoteURL])
    }

    func testFetchRejectsNonImageResponseBeforeWriting() async throws {
        let loader = ThumbnailDataLoader { _ in
            ThumbnailDownload(data: pngData, mimeType: "text/html")
        }
        let cache = ThumbnailCache(root: try temporaryDirectory(), loader: loader)
        let jobID = UUID()

        do {
            _ = try await cache.fetch(remoteURL: try XCTUnwrap(URL(string: "https://images.example.test/thumbnail.png")), for: jobID)
            XCTFail("Expected a non-image response to be rejected")
        } catch let error as ThumbnailCacheError {
            XCTAssertEqual(error, .unsupportedImageType)
        }
        let cachedURL = await cache.url(for: jobID)
        XCTAssertNil(cachedURL)
    }
}

private let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
private let jpegData = makeJPEGData(pixel: [0xFF, 0x00, 0x00, 0xFF])
private let replacementJPEGData = makeJPEGData(pixel: [0x00, 0x00, 0xFF, 0xFF])

private func makeJPEGData(pixel: [UInt8]) -> Data {
    let pixels = Data(pixel)
    let provider = CGDataProvider(data: pixels as CFData)!
    let image = CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

private enum ThumbnailFileFault: Equatable, CustomStringConvertible {
    case move
    case moveAfterMutation
    case read
    case remove
    case replace
    case replaceAfterMutation
    case write

    var description: String {
        switch self {
        case .move: "move"
        case .moveAfterMutation: "move after mutation"
        case .read: "read"
        case .remove: "remove"
        case .replace: "replace"
        case .replaceAfterMutation: "replace after mutation"
        case .write: "write"
        }
    }
}

private final class ThumbnailFaultFileSystem: ThumbnailFileSystem, @unchecked Sendable {
    private let fault: ThumbnailFileFault
    private let lock = NSLock()
    private var hasFailed = false
    private var matchingOperationCount = 0
    private let live = LiveThumbnailFileSystem()

    init(failingOnce fault: ThumbnailFileFault) {
        self.fault = fault
    }

    func createDirectory(at url: URL) throws {
        try live.createDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        live.fileExists(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try failIfNeeded(.read)
        return try live.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try failIfNeeded(.write)
        try live.writeData(data, to: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if try shouldFailAfterMutation(.moveAfterMutation) {
            try live.moveItem(at: sourceURL, to: destinationURL)
            throw CocoaError(.fileWriteUnknown)
        }
        try failIfNeeded(.move)
        try live.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL, backupItemName: String) throws -> URL? {
        if try shouldFailAfterMutation(.replaceAfterMutation) {
            _ = try live.replaceItem(at: originalURL, withItemAt: newURL, backupItemName: backupItemName)
            throw CocoaError(.fileWriteUnknown)
        }
        try failIfNeeded(.replace)
        return try live.replaceItem(at: originalURL, withItemAt: newURL, backupItemName: backupItemName)
    }

    func removeItem(at url: URL) throws {
        try failIfNeeded(.remove)
        try live.removeItem(at: url)
    }

    func isSymbolicLink(at url: URL) throws -> Bool {
        try live.isSymbolicLink(at: url)
    }

    private func failIfNeeded(_ operation: ThumbnailFileFault) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFailed, operation == fault else { return }
        matchingOperationCount += 1
        let failureIndex = fault == .read ? 2 : 1
        guard matchingOperationCount == failureIndex else { return }
        hasFailed = true
        throw CocoaError(.fileWriteUnknown)
    }

    private func shouldFailAfterMutation(_ operation: ThumbnailFileFault) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFailed, operation == fault else { return false }
        hasFailed = true
        return true
    }
}

private struct ThumbnailSymlinkFixture {
    let cache: ThumbnailCache
    let jobID: UUID
    let outsideFile: URL
}

private func makeDirectorySymlinkFixture() throws -> ThumbnailSymlinkFixture {
    let root = try temporaryDirectory()
    let outside = try temporaryDirectory()
    let jobID = UUID()
    let outsideFile = outside.appendingPathComponent("\(jobID.uuidString).png")
    try pngData.write(to: outsideFile)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("Thumbnails", isDirectory: true),
        withDestinationURL: outside
    )
    return ThumbnailSymlinkFixture(cache: ThumbnailCache(root: root), jobID: jobID, outsideFile: outsideFile)
}

private func makeLeafSymlinkFixture() throws -> ThumbnailSymlinkFixture {
    let root = try temporaryDirectory()
    let outside = try temporaryDirectory()
    let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
    try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
    let jobID = UUID()
    let outsideFile = outside.appendingPathComponent("outside.png")
    try pngData.write(to: outsideFile)
    try FileManager.default.createSymbolicLink(
        at: thumbnails.appendingPathComponent("\(jobID.uuidString).png"),
        withDestinationURL: outsideFile
    )
    return ThumbnailSymlinkFixture(cache: ThumbnailCache(root: root), jobID: jobID, outsideFile: outsideFile)
}

private func makeRootSymlinkFixture() throws -> ThumbnailSymlinkFixture {
    let parent = try temporaryDirectory()
    let outside = try temporaryDirectory()
    let thumbnails = outside.appendingPathComponent("Thumbnails", isDirectory: true)
    try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
    let jobID = UUID()
    let outsideFile = thumbnails.appendingPathComponent("\(jobID.uuidString).png")
    try pngData.write(to: outsideFile)
    let root = parent.appendingPathComponent("CacheRoot", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
    return ThumbnailSymlinkFixture(cache: ThumbnailCache(root: root), jobID: jobID, outsideFile: outsideFile)
}

private func thumbnailFileNames(in root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("Thumbnails", isDirectory: true),
        includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).sorted()
}

private func fileNumber(at url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}

private func assertUnsafeCachePath(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected unsafe cache path failure", file: file, line: line)
    } catch let error as ThumbnailCacheError {
        XCTAssertEqual(error, .unsafeCachePath, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private actor ThumbnailRequestRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}
