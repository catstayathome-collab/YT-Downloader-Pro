import Foundation
import XCTest
@testable import YTDownloaderPro2

final class ProgressParserTests: XCTestCase {
    func testParsesStructuredProgressTemplateWithWhitespaceAndPercentSign() {
        let events = ProgressParser().parse(
            line: "ytdp:progress| 67.5 % |245000000|366000000|12400000|12"
        )

        XCTAssertEqual(events, [
            .progress(
                .init(
                    fraction: 0.675,
                    downloadedBytes: 245000000,
                    totalBytes: 366000000,
                    bytesPerSecond: 12400000,
                    etaSeconds: 12
                )
            )
        ])
    }

    func testClampsPercentAndRejectsInvalidNumericFields() {
        let events = ProgressParser().parse(
            line: "ytdp:progress|140%|-1|NaN|infinity|-3"
        )

        XCTAssertEqual(events, [
            .progress(
                .init(
                    fraction: 1,
                    downloadedBytes: nil,
                    totalBytes: nil,
                    bytesPerSecond: nil,
                    etaSeconds: nil
                )
            )
        ])
    }

    func testPreservesProgressEventWhenTemplateNumericFieldsAreMissing() {
        let events = ProgressParser().parse(
            line: "ytdp:progress|N/A|N/A|N/A|N/A|N/A"
        )

        XCTAssertEqual(events, [
            .progress(
                .init(
                    fraction: nil,
                    downloadedBytes: nil,
                    totalBytes: nil,
                    bytesPerSecond: nil,
                    etaSeconds: nil
                )
            )
        ])
    }

    func testParsesPhasesFilepathAndCompletion() {
        let parser = ProgressParser()

        XCTAssertEqual(parser.parse(line: "ytdp:phase|downloading"), [.phase(.downloading)])
        XCTAssertEqual(parser.parse(line: "ytdp:phase|merging"), [.phase(.merging)])
        XCTAssertEqual(parser.parse(line: "ytdp:phase|postprocessing"), [.phase(.postprocessing)])
        XCTAssertEqual(
            parser.parse(line: "ytdp:filepath|/tmp/video.mp4"),
            [.output(URL(fileURLWithPath: "/tmp/video.mp4"))]
        )
        XCTAssertEqual(parser.parse(line: "ytdp:completed"), [.completed])
    }

    func testIgnoresMalformedAndHumanProgressLines() {
        let parser = ProgressParser()

        XCTAssertEqual(parser.parse(line: "ytdp:progress|not-a-percent"), [])
        XCTAssertEqual(parser.parse(line: "ytdp:filepath|relative.mp4"), [])
        XCTAssertEqual(parser.parse(line: "[download] 67.5% of 100MiB"), [])
    }

    func testDiagnosticFallbackRecognizesOnlyKnownMergerLineAndSanitizesDetail() {
        let parser = ProgressParser()
        let secret = "Authorization: Bearer never-show-this"

        let events = parser.parseDiagnostic(
            line: "[Merger] Merging formats into \"/tmp/video.mp4\" \(secret)"
        )

        XCTAssertEqual(events.first, .phase(.merging))
        XCTAssertFalse(events.contains { event in
            if case let .diagnostic(detail) = event {
                return detail.contains("never-show-this")
            }
            return false
        })
        XCTAssertEqual(parser.parseDiagnostic(line: "[download] 67.5% of 100MiB").count, 1)
    }

    func testLineBufferPreservesSplitUTF8AndFinalUnterminatedLine() {
        var buffer = ProcessLineBuffer()

        XCTAssertEqual(buffer.append(Data([0x66, 0x69, 0x72, 0x73, 0x74, 0x0A, 0x63, 0x61, 0x66])), ["first"])
        XCTAssertEqual(buffer.append(Data([0xC3])), [])
        XCTAssertEqual(buffer.append(Data([0xA9, 0x0A, 0xE6])), ["caf\u{00E9}"])
        XCTAssertEqual(buffer.append(Data([0xBC, 0xA2])), [])
        XCTAssertEqual(buffer.finish(), ["\u{6F22}"])
    }

    func testStreamingDeliversBothPipesBeforeOneTerminationEvent() async throws {
        let executable = try makeScript(
            """
            #!/bin/sh
            printf 'stdout-first\\nstdout-last\\n'
            printf 'stderr-first\\nstderr-last\\n' >&2
            exit 7
            """
        )
        let running = try await SystemProcessLauncher().start(executable: executable, arguments: [])
        let events = try await collect(running.events)

        XCTAssertEqual(events.filter { event in
            if case .terminated = event { return true }
            return false
        }, [.terminated(7)])
        XCTAssertTrue(events.contains(.stdoutLine("stdout-first")))
        XCTAssertTrue(events.contains(.stdoutLine("stdout-last")))
        XCTAssertTrue(events.contains(.stderrLine("stderr-first")))
        XCTAssertTrue(events.contains(.stderrLine("stderr-last")))
        XCTAssertEqual(events.last, .terminated(7))
    }

    func testStreamingEmitsFinalUnterminatedLinesAndEmptyOutputTerminates() async throws {
        let finalLineExecutable = try makeScript(
            """
            #!/bin/sh
            printf 'stdout-final'
            printf 'stderr-final' >&2
            """
        )
        let finalLineProcess = try await SystemProcessLauncher().start(
            executable: finalLineExecutable,
            arguments: []
        )
        let finalLineEvents = try await collect(finalLineProcess.events)

        XCTAssertTrue(finalLineEvents.contains(.stdoutLine("stdout-final")))
        XCTAssertTrue(finalLineEvents.contains(.stderrLine("stderr-final")))
        XCTAssertEqual(finalLineEvents.last, .terminated(0))

        let emptyExecutable = try makeScript("#!/bin/sh\nexit 0\n")
        let emptyProcess = try await SystemProcessLauncher().start(executable: emptyExecutable, arguments: [])
        let emptyEvents = try await collect(emptyProcess.events)
        XCTAssertEqual(emptyEvents, [.terminated(0)])
    }

    func testInterruptIsIdempotent() async throws {
        let running = try await SystemProcessLauncher().start(executable: try longRunningScript(), arguments: [])

        await running.interrupt()
        await running.interrupt()

        let events = try await collect(running.events)
        XCTAssertEqual(events.filter { event in
            if case .terminated = event { return true }
            return false
        }.count, 1)
    }

    func testTerminateIsIdempotent() async throws {
        let running = try await SystemProcessLauncher().start(executable: try longRunningScript(), arguments: [])

        await running.terminate()
        await running.terminate()

        let events = try await collect(running.events)
        XCTAssertEqual(events.filter { event in
            if case .terminated = event { return true }
            return false
        }.count, 1)
    }

    private func makeScript(_ script: String) throws -> URL {
        let executable = try temporaryDirectory().appendingPathComponent("process-fixture")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func longRunningScript() throws -> URL {
        try makeScript(
            """
            #!/bin/sh
            trap 'exit 0' INT TERM
            while :; do
                sleep 1
            done
            """
        )
    }
}
