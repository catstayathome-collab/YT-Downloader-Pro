import Darwin
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

    func testCaseVariantExistingFileCollidesOnCaseInsensitiveVolume() async throws {
        let root = try temporaryDirectory()
        try Data().write(to: root.appendingPathComponent("title.mp4"))
        let allocator = OutputNameAllocator(volumeSupportsCaseSensitiveNames: { _ in false })

        let reservation = try await allocator.reserve(
            title: "Title",
            extension: "mp4",
            directory: root,
            jobID: UUID()
        )

        XCTAssertEqual(reservation.baseURL.lastPathComponent, "Title (1)")
    }

    func testCanonicallyEquivalentUnicodeExistingFileAlwaysCollides() async throws {
        let root = try temporaryDirectory()
        try Data().write(to: root.appendingPathComponent("Cafe\u{301}.mp4"))
        let allocator = OutputNameAllocator(volumeSupportsCaseSensitiveNames: { _ in true })

        let reservation = try await allocator.reserve(
            title: "Caf\u{00E9}",
            extension: "mp4",
            directory: root,
            jobID: UUID()
        )

        XCTAssertEqual(reservation.baseURL.lastPathComponent, "Caf\u{00E9} (1)")
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

    func testFormatQualifiedVideoAndAudioArtifactsCauseCollision() async throws {
        // Matching only final extensions would reuse a yt-dlp format-qualified resume path.
        let artifactNames = [
            "Title.f137.mp4",
            "Title.f137.mp4.part",
            "Title.f137.mp4.ytdl",
            "Title.f137.mp4.part-Frag123",
            "Title.f251.webm.part-Frag9",
            "Title.f140.m4a.ytdl"
        ]

        for artifactName in artifactNames {
            let root = try temporaryDirectory()
            try Data().write(to: root.appendingPathComponent(artifactName))

            let reservation = try await OutputNameAllocator().reserve(
                title: "Title",
                extension: "mp4",
                directory: root,
                jobID: UUID()
            )

            XCTAssertEqual(reservation.baseURL.lastPathComponent, "Title (1)", artifactName)
        }
    }

    func testFormatQualifiedArtifactsRespectTheExactBasenameBoundary() async throws {
        // Prefix matching would incorrectly treat an unrelated "Title2" artifact as "Title".
        let root = try temporaryDirectory()
        try Data().write(to: root.appendingPathComponent("Title2.f137.mp4.part"))

        let reservation = try await OutputNameAllocator().reserve(
            title: "Title",
            extension: "mp4",
            directory: root,
            jobID: UUID()
        )

        XCTAssertEqual(reservation.baseURL.lastPathComponent, "Title")
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

    func testReleaseRechecksForeignMarkerWhileHoldingCooperativeLock() async throws {
        // Separating the ownership read from deletion would remove this replacement marker.
        let root = try temporaryDirectory()
        let gate = LockTestGate()
        let allocator = OutputNameAllocator(lockAcquiredHook: { _ in
            await gate.pauseWhenEnabled()
        })
        let jobID = UUID()
        let reservation = try await allocator.reserve(title: "Title", extension: "mp4", directory: root, jobID: jobID)
        let lockURL = URL(fileURLWithPath: reservation.markerURL.path + ".lock")
        await gate.enable()

        Task {
            await allocator.release(jobID: jobID, removeMarker: true)
            await gate.finishRelease()
        }
        await gate.waitForEntry()

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), -1)

        let foreignID = UUID()
        try foreignID.uuidString.data(using: .utf8)!.write(to: reservation.markerURL, options: .atomic)
        await gate.resume()
        await gate.waitForRelease()

        XCTAssertEqual(try String(contentsOf: reservation.markerURL, encoding: .utf8), foreignID.uuidString)
    }

    func testManyAllocatorInstancesReserveDistinctNamesUnderContention() async throws {
        // Removing the shared file lock permits different actors to pick the same basename.
        let root = try temporaryDirectory()
        let count = 32
        let gate = ContentionGate(participantCount: count)
        let allocators = (0..<count).map { _ in OutputNameAllocator() }

        let reservations = try await withThrowingTaskGroup(of: OutputReservation.self, returning: [OutputReservation].self) { group in
            for allocator in allocators {
                group.addTask {
                    await gate.wait()
                    return try await allocator.reserve(title: "Same", extension: "mp4", directory: root, jobID: UUID())
                }
            }

            var collected: [OutputReservation] = []
            for try await reservation in group {
                collected.append(reservation)
            }
            return collected
        }

        XCTAssertEqual(Set(reservations.map(\.baseURL)).count, count)
    }

    func testMaximumExtensionAndNumberedSuffixFitAllReservationArtifacts() async throws {
        // Ignoring lock-file and numbered-suffix space would exceed the macOS filename limit.
        let root = try temporaryDirectory()
        let title = String(repeating: "👩🏽‍🔬", count: 100)
        let fileExtension = String(repeating: "x", count: 64)
        let allocator = OutputNameAllocator()
        let firstJobID = UUID()
        let first = try await allocator.reserve(title: title, extension: fileExtension, directory: root, jobID: firstJobID)
        await allocator.release(jobID: firstJobID, removeMarker: true)
        try Data().write(to: first.baseURL.appendingPathExtension(fileExtension))

        let second = try await allocator.reserve(title: title, extension: fileExtension, directory: root, jobID: UUID())
        let filenames = [
            "\(second.baseURL.lastPathComponent).\(fileExtension)",
            second.markerURL.lastPathComponent,
            "\(second.markerURL.lastPathComponent).lock"
        ]

        XCTAssertTrue(second.baseURL.lastPathComponent.hasSuffix(" (1)"))
        XCTAssertTrue(filenames.allSatisfy { $0.lengthOfBytes(using: .utf8) <= 255 })
    }

    func testInvalidOrOversizedExtensionProducesStableSanitizedFailure() async throws {
        // Stripping invalid extension characters or accepting an oversized extension creates unsafe paths.
        let root = try temporaryDirectory()

        for fileExtension in ["mp/4", String(repeating: "x", count: 65)] {
            do {
                _ = try await OutputNameAllocator().reserve(title: "Title", extension: fileExtension, directory: root, jobID: UUID())
                XCTFail("Expected invalid extension failure for \(fileExtension)")
            } catch let failure as DownloadFailure {
                XCTAssertEqual(failure.category, .downloadFailed)
                XCTAssertEqual(failure.technicalDetail, "The selected output file extension is invalid.")
                XCTAssertFalse(failure.technicalDetail?.contains(fileExtension) ?? true)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
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
            XCTAssertEqual(failure.category, .outputPermissionDenied)
            XCTAssertEqual(failure.technicalDetail, "The selected download folder is unavailable or not writable.")
            XCTAssertFalse(failure.technicalDetail?.contains(directory.path) ?? true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor LockTestGate {
    private var enabled = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseFinished = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enable() {
        enabled = true
    }

    func pauseWhenEnabled() async {
        guard enabled else { return }
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func finishRelease() {
        releaseFinished = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForRelease() async {
        guard !releaseFinished else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

private actor ContentionGate {
    private let participantCount: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func wait() async {
        arrived += 1
        if arrived == participantCount {
            let currentWaiters = waiters
            waiters.removeAll()
            for waiter in currentWaiters {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
