import Foundation
import XCTest
@testable import YTDownloaderPro2

final class MP4WorkspaceTests: XCTestCase {
    func testRequestChangesInvalidateOldSubtitlesButSameRequestKeepsPartialDownload() throws {
        let directory = try temporaryDirectory()
        var job = DownloadJob(sourceURL: "https://youtu.be/test", title: "test", options: .fixture())
        let workspace = try MP4Workspace(directory: directory, jobID: job.id)
        try workspace.prepareRequest(for: job)
        let sidecar = workspace.directory.appendingPathComponent("source.ja.srt")
        let partial = workspace.directory.appendingPathComponent("source.mp4.part")
        try Data("old".utf8).write(to: sidecar)
        try Data("partial".utf8).write(to: partial)
        try workspace.prepareRequest(for: job)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        job.options.embedMetadata.toggle()
        try workspace.prepareRequest(for: job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testCancelledSourceHashDoesNotWriteReceipt() async throws {
        let directory = try temporaryDirectory()
        let job = DownloadJob(sourceURL: "https://youtu.be/test", title: "test", options: .fixture())
        let workspace = try MP4Workspace(directory: directory, jobID: job.id)
        try Data("source".utf8).write(to: workspace.source)
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try workspace.retainVerifiedSource(for: job)
        }
        do { try await worker.value; XCTFail("Cancelled hashing must stop") }
        catch is CancellationError {}
        XCTAssertFalse(workspace.hasVerifiedSource(for: job))
    }

    func testRecoveryReceiptRequiresSameRequestAndUnmodifiedSource() throws {
        let directory = try temporaryDirectory()
        var job = DownloadJob(sourceURL: "https://youtu.be/test", title: "test", options: .fixture())
        let workspace = try MP4Workspace(directory: directory, jobID: job.id)
        try Data("source".utf8).write(to: workspace.source)
        XCTAssertFalse(workspace.hasVerifiedSource(for: job))
        try workspace.retainVerifiedSource(for: job)
        XCTAssertTrue(workspace.hasVerifiedSource(for: job))
        job.sourceURL = "https://youtu.be/other"
        XCTAssertFalse(workspace.hasVerifiedSource(for: job))
        job.sourceURL = "https://youtu.be/test"
        try Data("tamper".utf8).write(to: workspace.source)
        XCTAssertFalse(workspace.hasVerifiedSource(for: job))
    }

    func testSidecarConflictRollsBackOnlyNewLinksAndCrashPublicationIsIdempotent() throws {
        let directory = try temporaryDirectory()
        let workspace = try MP4Workspace(directory: directory, jobID: UUID())
        try Data("media".utf8).write(to: workspace.candidate)
        try Data("caption".utf8).write(to: workspace.directory.appendingPathComponent("source.ja.srt"))
        let target = directory.appendingPathComponent("Video.mp4")
        let caption = directory.appendingPathComponent("Video.ja.srt")
        try Data("existing".utf8).write(to: caption)
        XCTAssertThrowsError(try workspace.publish(to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: caption, encoding: .utf8), "existing")
        try FileManager.default.removeItem(at: caption)
        try workspace.publish(to: target)
        XCTAssertTrue(workspace.isPublished(to: target))
        try workspace.publish(to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "media")
    }

    func testPublicationPreservesSidecarsAndDoesNotReplaceExistingMedia() throws {
        let directory = try temporaryDirectory()
        let workspace = try MP4Workspace(directory: directory, jobID: UUID())
        try Data("media".utf8).write(to: workspace.candidate)
        try Data("subtitle".utf8).write(to: workspace.directory.appendingPathComponent("source.zh-Hant.srt"))
        let destination = directory.appendingPathComponent("Video.mp4")
        try Data("existing".utf8).write(to: destination)
        XCTAssertThrowsError(try workspace.publish(to: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Video.zh-Hant.srt").path))
        try FileManager.default.removeItem(at: destination)
        try workspace.publish(to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "media")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("Video.zh-Hant.srt"), encoding: .utf8), "subtitle")
        try workspace.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWorkspaceRejectsForeignDirectoryAndSymlinkSource() throws {
        let directory = try temporaryDirectory()
        let id = UUID()
        let workspace = try MP4Workspace(directory: directory, jobID: id)
        let outside = directory.appendingPathComponent("outside.mp4")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: workspace.source, withDestinationURL: outside)
        XCTAssertThrowsError(try workspace.requireMedia(workspace.source))
        try Data("foreign".utf8).write(to: workspace.directory.appendingPathComponent("owner"))
        XCTAssertThrowsError(try MP4Workspace(directory: directory, jobID: id))
        XCTAssertThrowsError(try workspace.remove())
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
