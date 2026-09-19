import Foundation
import XCTest
@testable import YTDownloaderPro2

final class DiagnosticsLoggerTests: XCTestCase {
    func testClearRemovesOnlyKnownLogsAndInterruptedRotationFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Diagnostics")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["diagnostics.jsonl", "diagnostics.rotation.json"]
            + (1...3).map { "diagnostics.\($0).jsonl" }
            + (0...3).map { "diagnostics.rotation-backup-\($0).jsonl" }
        for name in names + ["keep.txt", "diagnostics.4.jsonl"] {
            try Data("unparsed".utf8).write(to: directory.appendingPathComponent(name))
        }
        let logger = DiagnosticsLogger(root: root)
        try await logger.clear()
        try await logger.clear()
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["keep.txt", "diagnostics.4.jsonl"]))
        let event = DiagnosticEvent(jobID: UUID(), stage: "new")
        try await logger.record(event)
        let details = try await logger.details(for: XCTUnwrap(event.jobID))
        XCTAssertEqual(details, [event])
    }

    func testClearRejectsDirectoryAtLogFilenameWithoutDeletingItsContents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Diagnostics/diagnostics.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keep = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        do {
            try await DiagnosticsLogger(root: root).clear()
            XCTFail("Expected an error, not recursive deletion")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    func testExportLinesAreBoundedNewestFirstAndSkipMalformedRecords() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DiagnosticsLogger(root: root)
        for number in 0..<5 {
            try await logger.record(DiagnosticEvent(stage: "stage-\(number)"))
        }
        let url = await logger.currentLogURL
        var data = try Data(contentsOf: url)
        data.append(Data("malformed\n".utf8))
        try data.write(to: url)
        let lines = try await logger.exportLines(maximumLines: 2)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("stage-4"))
        XCTAssertTrue(lines[1].contains("stage-3"))
        let empty = try await logger.exportLines(maximumLines: 0)
        XCTAssertEqual(empty, [])
    }

    func testClearFailureCanBeRetriedWithoutRestoringOldEvents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FaultingDiagnosticsFileSystem(failingOnce: .remove("diagnostics.jsonl"))
        let logger = DiagnosticsLogger(root: root, fileSystem: fs)
        let id = UUID()
        try await logger.record(DiagnosticEvent(jobID: id, stage: "old"))
        do {
            try await logger.clear()
            XCTFail("Expected deletion failure")
        } catch {}
        try await logger.clear()
        let details = try await DiagnosticsLogger(root: root).details(for: id)
        XCTAssertTrue(details.isEmpty)
    }

    func testMaintenanceRejectsSymlinkedDiagnosticsDirectory() async throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let keep = outside.appendingPathComponent("diagnostics.jsonl")
        try Data("private".utf8).write(to: keep)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Diagnostics"),
                                                 withDestinationURL: outside)
        let logger = DiagnosticsLogger(root: root)
        do { try await logger.clear(); XCTFail("Expected rejection") } catch {}
        do { _ = try await logger.exportLines(); XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(try Data(contentsOf: keep), Data("private".utf8))
    }

    func testAllCredentialURLAndCookiePathFormsAreRedactedBeforeDiskWrite() async throws {
        let logger = DiagnosticsLogger(root: try temporaryDirectory())
        let event = DiagnosticEvent(
            jobID: UUID(),
            stage: "download",
            arguments: [
                "-u", "short-user",
                "-p", "short-password",
                "--username=long-user",
                "--password", "long-password",
                "--cookies", "/Users/example/Library/Application Support/browser/cookies.sqlite",
                "--cookies-from-browser=chrome:Profile 1",
                "--proxy", "https://proxy-user:proxy-password@proxy.test:8443/tunnel?session=proxy-query#proxy-fragment",
                "--geo-verification-proxy=socks5://geo-user:geo-password@geo-proxy.test:1080?route=geo-query#geo-fragment",
                "https://url-user:url-password@media.test/watch?v=query-value&list=playlist-value#url-fragment"
            ],
            technicalDetail: """
            Loading cookies from /Users/example/Library/Cookies/private-cookies.txt
            Proxy tunnel: socks5://detail-user:detail-password@proxy.test:1080/path?token=detail-query#detail-fragment
            Command output: yt-dlp -u output-user -p output-password --cookies /tmp/output-cookies.txt
            Credentials username=prose-user password: prose-password; bearer bearer-secret
            Safe context: HTTP 403 while opening /watch
            """
        )

        try await logger.record(event)

        let logURL = await logger.currentLogURL
        let text = try String(contentsOf: logURL, encoding: .utf8)
        let secrets = [
            "short-user", "short-password", "long-user", "long-password",
            "cookies.sqlite", "Profile 1", "proxy-user", "proxy-password", "proxy-query", "proxy-fragment",
            "geo-user", "geo-password", "geo-query", "geo-fragment",
            "url-user", "url-password", "query-value", "playlist-value", "url-fragment",
            "private-cookies.txt", "detail-user", "detail-password", "detail-query", "detail-fragment",
            "output-user", "output-password", "output-cookies.txt",
            "prose-user", "prose-password", "bearer-secret"
        ]
        for secret in secrets {
            XCTAssertFalse(text.contains(secret), "Serialized diagnostics leaked \(secret)")
        }
        XCTAssertTrue(text.contains("proxy.test"))
        XCTAssertTrue(text.contains("media.test"))
        XCTAssertTrue(text.contains("/watch"))
        XCTAssertTrue(text.contains("session"))
        XCTAssertTrue(text.contains("route"))
        XCTAssertTrue(text.contains("list"))
        XCTAssertTrue(text.contains("Safe context: HTTP 403"))
        XCTAssertTrue(text.contains("[REDACTED]"))
    }

    func testOutputPathArgumentsAreRedactedBeforeDiskWrite() async throws {
        let logger = DiagnosticsLogger(root: try temporaryDirectory())
        let event = DiagnosticEvent(
            jobID: UUID(),
            stage: "download",
            arguments: [
                "--output", "/Users/example/Movies/private-template/%(title)s.%(ext)s",
                "-o=/Users/example/Downloads/short-template.%(ext)s",
                "--paths", "home:/Users/example/Media Library",
                "-P", "temp:/private/tmp/ytdp-fragments"
            ],
            technicalDetail: """
            Command output: yt-dlp --output /Users/example/Movies/private-template/%(title)s.%(ext)s \
            -o /Users/example/Downloads/short-template.%(ext)s \
            --paths home:/Users/example/Media Library -P temp:/private/tmp/ytdp-fragments
            Safe context: output template rejected
            """
        )

        try await logger.record(event)

        let logURL = await logger.currentLogURL
        let text = try String(contentsOf: logURL, encoding: .utf8)
        for pathFragment in [
            "private-template", "short-template", "Media Library", "ytdp-fragments"
        ] {
            XCTAssertFalse(text.contains(pathFragment), "Serialized diagnostics leaked \(pathFragment)")
        }
        XCTAssertTrue(text.contains("Safe context: output template rejected"))
        XCTAssertTrue(text.contains("[REDACTED]"))
    }

    func testSecretsAreRedactedBeforeDiskWrite() async throws {
        let logger = DiagnosticsLogger(root: try temporaryDirectory())
        let event = DiagnosticEvent(
            jobID: UUID(),
            stage: "download",
            arguments: [
                "--cookies", "/Users/example/Library/Cookies.txt",
                "--http-header", "Authorization: Bearer authorization-secret",
                "https://x.test/watch?v=public&sig=url-signature"
            ],
            technicalDetail: "Cookie: SID=browser-secret\nRetrying https://x.test/watch?v=public&token=url-token"
        )

        try await logger.record(event)

        let logURL = await logger.currentLogURL
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(text.contains("Cookies.txt"))
        XCTAssertFalse(text.contains("authorization-secret"))
        XCTAssertFalse(text.contains("browser-secret"))
        XCTAssertFalse(text.contains("url-signature"))
        XCTAssertFalse(text.contains("url-token"))
        XCTAssertFalse(text.contains("v=public"))
        XCTAssertTrue(text.contains("[REDACTED]"))
    }

    func testDetailsReturnsOnlyTheRequestedJobAndDecodedJSONL() async throws {
        let logger = DiagnosticsLogger(root: try temporaryDirectory())
        let wanted = UUID()
        let other = UUID()
        try await logger.record(DiagnosticEvent(jobID: wanted, stage: "download", arguments: ["--format", "best"]))
        try await logger.record(DiagnosticEvent(jobID: other, stage: "merge", arguments: ["--embed-metadata"]))

        let details = try await logger.details(for: wanted)
        let logURL = await logger.currentLogURL
        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")

        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details.first?.jobID, wanted)
        XCTAssertEqual(lines.count, 2)
        XCTAssertNotNil(try? JSONDecoder().decode(DiagnosticEvent.self, from: Data(lines[0].utf8)))
    }

    func testExistingLogReadFailurePreservesPriorBytesAndPropagates() async throws {
        let root = try temporaryDirectory()
        let fileSystem = FaultingDiagnosticsFileSystem()
        let logger = DiagnosticsLogger(root: root, fileSystem: fileSystem)
        let first = DiagnosticEvent(jobID: UUID(), stage: "first")
        try await logger.record(first)
        let logURL = await logger.currentLogURL
        let priorBytes = try Data(contentsOf: logURL)
        fileSystem.failNextRead()

        do {
            try await logger.record(DiagnosticEvent(jobID: UUID(), stage: "second"))
            XCTFail("Expected existing-log read failure")
        } catch {
            XCTAssertEqual(try Data(contentsOf: logURL), priorBytes)
        }
    }

    func testValidJSONLEventsRotateBelowExactAndAboveFiveMegabytes() async throws {
        let jobID = UUID()
        for (offset, shouldRotate) in [(-1, false), (0, true), (1, true)] {
            let root = try temporaryDirectory()
            let logger = DiagnosticsLogger(root: root)
            let currentURL = await logger.currentLogURL
            try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let eventID = UUID()
            let line = paddedDiagnosticLine(
                id: eventID,
                jobID: jobID,
                byteCount: DiagnosticsLogger.maximumLogBytes + offset
            )
            try line.write(to: currentURL)

            try await logger.rotateIfNeeded()

            let details = try await logger.details(for: jobID)
            XCTAssertEqual(details.map(\.id), [eventID])
            let rotatedURL = currentURL.deletingLastPathComponent().appendingPathComponent("diagnostics.1.jsonl")
            XCTAssertEqual(FileManager.default.fileExists(atPath: rotatedURL.path), shouldRotate)
            XCTAssertEqual(FileManager.default.fileExists(atPath: currentURL.path), !shouldRotate)
        }
    }

    func testDetailsSearchesCurrentThenRetainedGenerationsNewestToOldest() async throws {
        let root = try temporaryDirectory()
        let logger = DiagnosticsLogger(root: root)
        let currentURL = await logger.currentLogURL
        try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let jobID = UUID()
        let ids = (0..<4).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            let url = index == 0
                ? currentURL
                : currentURL.deletingLastPathComponent().appendingPathComponent("diagnostics.\(index).jsonl")
            try diagnosticLine(id: id, jobID: jobID, stage: "generation-\(index)").write(to: url)
        }

        let details = try await logger.details(for: jobID)

        XCTAssertEqual(details.map(\.id), ids)
    }

    func testRotationRecoversFromEveryMoveAndRemoveBoundaryWithoutDuplicateEvents() async throws {
        let failures: [DiagnosticFileMutation] = [
            .move("diagnostics.jsonl", "diagnostics.rotation-backup-0.jsonl"),
            .move("diagnostics.1.jsonl", "diagnostics.rotation-backup-1.jsonl"),
            .move("diagnostics.2.jsonl", "diagnostics.rotation-backup-2.jsonl"),
            .move("diagnostics.3.jsonl", "diagnostics.rotation-backup-3.jsonl"),
            .move("diagnostics.rotation-backup-0.jsonl", "diagnostics.1.jsonl"),
            .move("diagnostics.rotation-backup-1.jsonl", "diagnostics.2.jsonl"),
            .move("diagnostics.rotation-backup-2.jsonl", "diagnostics.3.jsonl"),
            .remove("diagnostics.rotation-backup-3.jsonl"),
            .remove("diagnostics.rotation.json")
        ]

        for failure in failures {
            let root = try temporaryDirectory()
            let jobID = UUID()
            let ids = (0..<4).map { _ in UUID() }
            try writeFourGenerations(root: root, jobID: jobID, ids: ids)
            let fileSystem = FaultingDiagnosticsFileSystem(failingOnce: failure)
            let logger = DiagnosticsLogger(root: root, fileSystem: fileSystem)

            do {
                try await logger.rotateIfNeeded()
                XCTFail("Expected injected failure at \(failure)")
            } catch {
                let details = try await logger.details(for: jobID)
                let recoveredIDs = details.map(\.id)
                XCTAssertTrue(
                    recoveredIDs == ids || recoveredIDs == Array(ids.prefix(3)),
                    "Unexpected retained generations after \(failure): \(recoveredIDs)"
                )
                XCTAssertEqual(Set(recoveredIDs).count, recoveredIDs.count)
            }
        }
    }
}

private enum DiagnosticFileMutation: Equatable, CustomStringConvertible {
    case move(String, String)
    case remove(String)

    var description: String {
        switch self {
        case let .move(source, destination): "move \(source) -> \(destination)"
        case let .remove(name): "remove \(name)"
        }
    }
}

private final class FaultingDiagnosticsFileSystem: DiagnosticsFileSystem, @unchecked Sendable {
    private let live = LiveDiagnosticsFileSystem()
    private let lock = NSLock()
    private var pendingMutation: DiagnosticFileMutation?
    private var shouldFailRead = false

    init(failingOnce mutation: DiagnosticFileMutation? = nil) {
        pendingMutation = mutation
    }

    func failNextRead() {
        lock.lock()
        shouldFailRead = true
        lock.unlock()
    }

    func createDirectory(at url: URL) throws {
        try live.createDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        live.fileExists(at: url)
    }

    func readData(at url: URL) throws -> Data {
        lock.lock()
        let fail = shouldFailRead
        shouldFailRead = false
        lock.unlock()
        if fail { throw CocoaError(.fileReadUnknown) }
        return try live.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try live.writeData(data, to: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try failIfNeeded(.move(sourceURL.lastPathComponent, destinationURL.lastPathComponent))
        try live.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try failIfNeeded(.remove(url.lastPathComponent))
        try live.removeItem(at: url)
    }

    private func failIfNeeded(_ mutation: DiagnosticFileMutation) throws {
        lock.lock()
        defer { lock.unlock() }
        guard pendingMutation == mutation else { return }
        pendingMutation = nil
        throw CocoaError(.fileWriteUnknown)
    }
}

private func diagnosticLine(id: UUID, jobID: UUID, stage: String, detail: String? = nil) -> Data {
    let event = DiagnosticEvent(
        id: id,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        jobID: jobID,
        stage: stage,
        technicalDetail: detail
    )
    var data = try! JSONEncoder().encode(event)
    data.append(0x0A)
    return data
}

private func paddedDiagnosticLine(id: UUID, jobID: UUID, byteCount: Int) -> Data {
    let empty = diagnosticLine(id: id, jobID: jobID, stage: "threshold", detail: "")
    precondition(byteCount >= empty.count)
    let padding = String(repeating: "x", count: byteCount - empty.count)
    let padded = diagnosticLine(id: id, jobID: jobID, stage: "threshold", detail: padding)
    precondition(padded.count == byteCount)
    return padded
}

private func writeFourGenerations(root: URL, jobID: UUID, ids: [UUID]) throws {
    let directory = root.appendingPathComponent("Diagnostics", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (index, id) in ids.enumerated() {
        let url = index == 0
            ? directory.appendingPathComponent("diagnostics.jsonl")
            : directory.appendingPathComponent("diagnostics.\(index).jsonl")
        let line = index == 0
            ? paddedDiagnosticLine(id: id, jobID: jobID, byteCount: DiagnosticsLogger.maximumLogBytes)
            : diagnosticLine(id: id, jobID: jobID, stage: "generation-\(index)")
        try line.write(to: url)
    }
}
