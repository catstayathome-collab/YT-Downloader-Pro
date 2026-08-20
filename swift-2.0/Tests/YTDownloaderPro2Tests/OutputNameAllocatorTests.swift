import Foundation
import XCTest
@testable import YTDownloaderPro2

final class OutputNameAllocatorTests: XCTestCase {
    func testExistingFinalFileSelectsFirstNumberedBasename() async throws {
        // Removing the selected-file collision check would return "Title".
        let root = try temporaryDirectory()
        try Data().write(to: root.appendingPathComponent("Title.mp4"))

        let reservation = try await OutputNameAllocator().reserve(
            title: "Title",
            extension: "mp4",
            directory: root,
            jobID: UUID()
        )

        XCTAssertEqual(reservation.baseURL.lastPathComponent, "Title (1)")
    }

    func testExistingNumberedFilesAdvanceToFirstFreeBasename() async throws {
        // Starting numbering at the wrong slot would fail this hand-derived sequence.
        let root = try temporaryDirectory()
        for name in ["Title.mp4", "Title (1).mp4", "Title (2).mp4", "Title (4).mp4"] {
            try Data().write(to: root.appendingPathComponent(name))
        }

        let reservation = try await OutputNameAllocator().reserve(
            title: "Title",
            extension: "mp4",
            directory: root,
            jobID: UUID()
        )

        XCTAssertEqual(reservation.baseURL.lastPathComponent, "Title (3)")
    }

    func testConcurrentReservationsFromOneAllocatorNeverMatch() async throws {
        // Removing actor-owned reservation state would allow duplicate basenames.
        let root = try temporaryDirectory()
        let allocator = OutputNameAllocator()

        async let first = allocator.reserve(title: "Same", extension: "mp4", directory: root, jobID: UUID())
        async let second = allocator.reserve(title: "Same", extension: "mp4", directory: root, jobID: UUID())
        let reservations = try await [first, second]

        XCTAssertEqual(Set(reservations.map(\.baseURL)).count, 2)
    }

    func testConcurrentReservationsFromSeparateAllocatorsNeverMatch() async throws {
        // Replacing exclusive marker creation with a preflight-only check would duplicate "Same".
        let root = try temporaryDirectory()
        let firstAllocator = OutputNameAllocator()
        let secondAllocator = OutputNameAllocator()

        async let first = firstAllocator.reserve(title: "Same", extension: "mp4", directory: root, jobID: UUID())
        async let second = secondAllocator.reserve(title: "Same", extension: "mp4", directory: root, jobID: UUID())
        let reservations = try await [first, second]

        XCTAssertEqual(Set(reservations.map(\.baseURL)).count, 2)
    }

    func testSanitizationPreservesUnicodeAndUsesFallbackForEmptyOrReservedNames() async throws {
        // Permitting separators or accepting an empty basename would violate the output template contract.
        let root = try temporaryDirectory()
        let allocator = OutputNameAllocator()

        let sanitized = try await allocator.reserve(
            title: "  . 學習/動画:第1話? .  ",
            extension: ".mp4",
            directory: root,
            jobID: UUID()
        )
        let empty = try await allocator.reserve(title: " /:*?<>|\\\"\n\u{0001} . ", extension: "mp4", directory: root, jobID: UUID())
        let reserved = try await allocator.reserve(title: "..", extension: "mp4", directory: root, jobID: UUID())

        XCTAssertEqual(sanitized.baseURL.lastPathComponent, "學習動画第1話")
        XCTAssertEqual(empty.baseURL.lastPathComponent, "Untitled Download")
        XCTAssertEqual(reserved.baseURL.lastPathComponent, "Untitled Download (1)")
    }

    func testLongUnicodeNameFitsFilenameLimitWithoutSplittingGraphemeOrExtension() async throws {
        // Byte-truncating a String would split this multi-scalar grapheme or lose the extension room.
        let root = try temporaryDirectory()
        let title = String(repeating: "👩🏽‍🔬", count: 100)

        let reservation = try await OutputNameAllocator().reserve(
            title: title,
            extension: "mp4",
            directory: root,
            jobID: UUID()
        )

        let finalName = "\(reservation.baseURL.lastPathComponent).mp4"
        XCTAssertLessThanOrEqual(finalName.lengthOfBytes(using: .utf8), 255)
        XCTAssertTrue(reservation.baseURL.lastPathComponent.allSatisfy { $0 == "👩🏽‍🔬" })
        XCTAssertTrue(finalName.hasSuffix(".mp4"))
    }

    func testPartialAndAlternateContainerArtifactsCauseCollision() async throws {
        // Checking only the selected extension would overwrite a merge artifact or resumable partial.
        let root = try temporaryDirectory()
        try Data().write(to: root.appendingPathComponent("Title.webm.part"))
        try Data().write(to: root.appendingPathComponent("Title.m4a"))

        let reservation = try await OutputNameAllocator().reserve(
            title: "Title",
            extension: "mp4",
            directory: root,
            jobID: UUID()
        )

        XCTAssertEqual(reservation.baseURL.lastPathComponent, "Title (1)")
    }

    func testReserveReturnsSameOwnedPersistedMarkerForSameJob() async throws {
        // Ignoring persisted ownership would change the basename after an app relaunch.
        let root = try temporaryDirectory()
        let jobID = UUID()
        let first = try await OutputNameAllocator().reserve(title: "Title", extension: "mp4", directory: root, jobID: jobID)

        let second = try await OutputNameAllocator().reserve(title: "Different", extension: "mp4", directory: root, jobID: jobID)

        XCTAssertEqual(second, first)
    }

    func testPausedReleaseKeepsMarkerAndTerminalReleaseRemovesOnlyOwnedMarker() async throws {
        // Removing every marker on release would break resume and delete another job's ownership.
        let root = try temporaryDirectory()
        let allocator = OutputNameAllocator()
        let jobID = UUID()
        let reservation = try await allocator.reserve(title: "Title", extension: "mp4", directory: root, jobID: jobID)

        await allocator.release(jobID: jobID, removeMarker: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservation.markerURL.path))

        let resumed = try await allocator.reserve(title: "Title", extension: "mp4", directory: root, jobID: jobID)
        XCTAssertEqual(resumed, reservation)
        await allocator.release(jobID: jobID, removeMarker: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumed.markerURL.path))
    }

    func testTerminalReleaseDoesNotRemoveMarkerReplacedByAnotherJob() async throws {
        // Removing a marker without verifying its UUID would delete another job's ownership.
        let root = try temporaryDirectory()
        let allocator = OutputNameAllocator()
        let jobID = UUID()
        let reservation = try await allocator.reserve(title: "Title", extension: "mp4", directory: root, jobID: jobID)
        let foreignID = UUID()
        try foreignID.uuidString.data(using: .utf8)!.write(to: reservation.markerURL, options: .atomic)

        await allocator.release(jobID: jobID, removeMarker: true)

        XCTAssertEqual(try String(contentsOf: reservation.markerURL, encoding: .utf8), foreignID.uuidString)
    }

    func testForeignOrMalformedMarkerIsNeverAdoptedOrDeleted() async throws {
        // Treating any marker as ours would reuse or delete foreign ownership.
        let root = try temporaryDirectory()
        let foreignMarker = root.appendingPathComponent(".Title.ytdp-reservation")
        try Data("not-a-uuid".utf8).write(to: foreignMarker)
        let allocator = OutputNameAllocator()

        let reservation = try await allocator.reserve(title: "Title", extension: "mp4", directory: root, jobID: UUID())
        await allocator.release(jobID: UUID(), removeMarker: true)

        XCTAssertEqual(reservation.baseURL.lastPathComponent, "Title (1)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignMarker.path))
    }

    func testInvalidOrUnwritableDestinationProducesStableSanitizedFailure() async throws {
        // Leaking filesystem paths or POSIX errors would make the user-facing failure unstable.
        let root = try temporaryDirectory()
        let fileDestination = root.appendingPathComponent("not-a-folder")
        try Data().write(to: fileDestination)

        await assertDestinationFailure(for: fileDestination)

        let readOnlyDirectory = root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDirectory.path)
        }

        await assertDestinationFailure(for: readOnlyDirectory)
    }

    private func assertDestinationFailure(for directory: URL) async {
        do {
            _ = try await OutputNameAllocator().reserve(title: "Title", extension: "mp4", directory: directory, jobID: UUID())
            XCTFail("Expected output-directory failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .unknown)
            XCTAssertEqual(failure.technicalDetail, "The selected download folder is unavailable or not writable.")
            XCTAssertFalse(failure.technicalDetail?.contains(directory.path) ?? true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
