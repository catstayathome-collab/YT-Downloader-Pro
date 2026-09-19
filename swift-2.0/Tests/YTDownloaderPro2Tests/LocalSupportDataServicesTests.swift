import Foundation
import XCTest
@testable import YTDownloaderPro2

final class LocalSupportDataServicesTests: XCTestCase {
    func testSupportWriterCreatesOneDecodableLocalJSONFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = supportDraft()

        let writtenURL = try LocalSupportReportWriter().write(draft, to: root)

        XCTAssertEqual(writtenURL.deletingLastPathComponent(), root)
        XCTAssertEqual(writtenURL.pathExtension, "json")
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).map { $0.resolvingSymlinksInPath().standardizedFileURL }
        XCTAssertEqual(
            directoryContents,
            [writtenURL.resolvingSymlinksInPath().standardizedFileURL]
        )
        let decoded = try JSONDecoder().decode(
            SupportReportDraft.self,
            from: Data(contentsOf: writtenURL)
        )
        XCTAssertEqual(decoded, draft)
    }

    func testSupportWriterAllocatesANewNameWithoutOverwritingExistingReport() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = supportDraft()
        let writer = LocalSupportReportWriter()

        let firstURL = try writer.write(draft, to: root)
        let originalData = try Data(contentsOf: firstURL)
        let secondURL = try writer.write(draft, to: root)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), originalData)
    }

    func testSupportWriterBytesMatchTheReviewedExactPreview() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = supportDraft()
        let preview = try SupportReportJSONPreview(draft: draft)

        let writtenURL = try LocalSupportReportWriter().write(draft, to: root)

        XCTAssertEqual(
            String(decoding: try Data(contentsOf: writtenURL), as: UTF8.self),
            preview.payload
        )
    }

    func testExportWriterCreatesOnlyTheFiveReviewedJSONFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = DownloadJob(
            sourceURL: "https://user:secret@example.com/watch?v=private",
            title: "Private title",
            status: .completed,
            outputURL: root.appendingPathComponent("downloaded-video.mp4"),
            options: .defaults
        )
        let draft = LocalDataExportDraft.defaultPreview(
            appVersion: "2.0.0",
            releaseChannel: "test",
            exportDate: Date(timeIntervalSince1970: 100),
            jobs: [job],
            settings: .defaults,
            diagnosticLines: ["safe diagnostic"]
        )

        let packageURL = try LocalExportPackageWriter().write(draft, to: root)

        XCTAssertEqual(packageURL.pathExtension, "ytdpexport")
        let names = try FileManager.default.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        XCTAssertEqual(
            names,
            ["diagnostics.json", "jobs.json", "manifest.json", "settings.json", "thumbnails.json"]
        )
        XCTAssertFalse(names.contains("downloaded-video.mp4"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                LocalDataExportDraft.Manifest.self,
                from: Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))
            ),
            draft.manifest
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [DownloadJob].self,
                from: Data(contentsOf: packageURL.appendingPathComponent("jobs.json"))
            ),
            draft.jobs
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppSettings.self,
                from: Data(contentsOf: packageURL.appendingPathComponent("settings.json"))
            ),
            draft.settings
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [LocalDataExportDraft.ThumbnailReference].self,
                from: Data(contentsOf: packageURL.appendingPathComponent("thumbnails.json"))
            ),
            draft.thumbnailReferences
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [String].self,
                from: Data(contentsOf: packageURL.appendingPathComponent("diagnostics.json"))
            ),
            draft.diagnosticExcerpt
        )
    }

    func testWritersRejectNonFileDestinationsAndRegularFilesAsDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let regularFile = root.appendingPathComponent("not-a-directory")
        try Data().write(to: regularFile)

        XCTAssertThrowsError(
            try LocalSupportReportWriter().write(supportDraft(), to: URL(string: "https://example.com")!)
        ) { error in
            XCTAssertEqual(error as? LocalSupportDataServiceError, .invalidDestination)
        }
        XCTAssertThrowsError(
            try LocalExportPackageWriter().write(exportDraft(), to: regularFile)
        ) { error in
            XCTAssertEqual(error as? LocalSupportDataServiceError, .destinationNotDirectory)
        }
    }

    func testSelectedMediaDeleterRemovesOnlyAnExplicitRegularFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaURL = root.appendingPathComponent("selected.mp4")
        try Data("media".utf8).write(to: mediaURL)

        try SelectedMediaFileDeleter().delete(mediaURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testSelectedMediaDeleterRejectsMissingDirectoryAndSymbolicLinkTargets() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.mp4")
        let directoryURL = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let mediaURL = root.appendingPathComponent("actual.mp4")
        let symbolicLinkURL = root.appendingPathComponent("linked.mp4")
        try Data("media".utf8).write(to: mediaURL)
        try FileManager.default.createSymbolicLink(at: symbolicLinkURL, withDestinationURL: mediaURL)

        XCTAssertThrowsError(try SelectedMediaFileDeleter().delete(missingURL)) { error in
            XCTAssertEqual(error as? LocalSupportDataServiceError, .mediaFileUnavailable)
        }
        XCTAssertThrowsError(try SelectedMediaFileDeleter().delete(directoryURL)) { error in
            XCTAssertEqual(error as? LocalSupportDataServiceError, .unsafeMediaSelection)
        }
        XCTAssertThrowsError(try SelectedMediaFileDeleter().delete(symbolicLinkURL)) { error in
            XCTAssertEqual(error as? LocalSupportDataServiceError, .unsafeMediaSelection)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))
    }

    private func supportDraft() -> SupportReportDraft {
        SupportReportDraft.defaultPreview(
            category: .privacy,
            subject: "Local report",
            message: "Reviewed message",
            environment: .init(
                appVersion: "2.0.0",
                releaseChannel: "test",
                macOSVersion: "15.0",
                architecture: "arm64",
                localeIdentifier: "zh-Hant"
            ),
            incidentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }

    private func exportDraft() -> LocalDataExportDraft {
        LocalDataExportDraft.defaultPreview(
            appVersion: "2.0.0",
            releaseChannel: "test",
            jobs: [],
            settings: .defaults
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalSupportDataServicesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
