import Foundation
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

private let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
private let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0xFF, 0xD9])

private actor ThumbnailRequestRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}
