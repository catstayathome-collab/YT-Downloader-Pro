import Foundation
import XCTest
@testable import YTDownloaderPro2

final class DiagnosticsLoggerTests: XCTestCase {
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

    func testRotationUsesFiveMegabytesAndRetainsExactlyThreeFiles() async throws {
        let root = try temporaryDirectory()
        let logger = DiagnosticsLogger(root: root)
        let currentURL = await logger.currentLogURL
        try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        XCTAssertEqual(DiagnosticsLogger.maximumLogBytes, 5 * 1024 * 1024)
        for cycle in 1...4 {
            try Data(repeating: UInt8(cycle), count: DiagnosticsLogger.maximumLogBytes).write(to: currentURL)
            try await logger.rotateIfNeeded()
        }

        let diagnosticsDirectory = root.appendingPathComponent("Diagnostics", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticsDirectory.appendingPathComponent("diagnostics.1.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticsDirectory.appendingPathComponent("diagnostics.2.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticsDirectory.appendingPathComponent("diagnostics.3.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnosticsDirectory.appendingPathComponent("diagnostics.4.jsonl").path))
    }
}
