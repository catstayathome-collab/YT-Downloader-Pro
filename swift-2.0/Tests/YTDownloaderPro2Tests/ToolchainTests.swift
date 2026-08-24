import Foundation
import XCTest
@testable import YTDownloaderPro2

final class ToolchainTests: XCTestCase {
    func testResolveUsesOnlyContentsHelpers() throws {
        let bundle = try makeBundle(helperNames: ["yt-dlp_macos", "ffmpeg", "ffprobe", "qjs"])
        let nonCanonicalFFmpeg = bundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("ffmpeg")
        try makeExecutable(at: nonCanonicalFFmpeg, script: "#!/bin/sh\necho wrong\n")

        let toolchain = try Toolchain.resolve(bundle: bundle)

        XCTAssertEqual(
            toolchain.ffmpeg,
            bundle.appendingPathComponent("Contents/Helpers/ffmpeg")
        )
    }

    func testResolveRejectsMissingCanonicalHelperEvenWhenItExistsElsewhere() throws {
        let bundle = try makeBundle(helperNames: ["yt-dlp_macos", "ffmpeg", "ffprobe"])
        let nonCanonicalQJS = bundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("qjs")
        try makeExecutable(at: nonCanonicalQJS, script: "#!/bin/sh\necho QuickJS version 2025\n")

        XCTAssertThrowsError(try Toolchain.resolve(bundle: bundle)) { error in
            XCTAssertEqual((error as? DownloadFailure)?.category, .bundledDownloaderUnavailable)
        }
    }

    func testResolveRejectsNonExecutableHelper() throws {
        let bundle = try makeBundle(helperNames: ["yt-dlp_macos", "ffmpeg", "ffprobe", "qjs"])
        let ffmpeg = bundle.appendingPathComponent("Contents/Helpers/ffmpeg")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ffmpeg.path)

        XCTAssertThrowsError(try Toolchain.resolve(bundle: bundle)) { error in
            XCTAssertEqual((error as? DownloadFailure)?.category, .bundledConverterUnavailable)
        }
    }

    func testResolveRejectsSymlinkEscapeOutsideHelpers() throws {
        let bundle = try makeBundle(helperNames: ["yt-dlp_macos", "ffmpeg", "ffprobe", "qjs"])
        let helpers = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let escapedHelper = bundle.appendingPathComponent("Contents/escaped-qjs")
        try makeExecutable(at: escapedHelper, script: "#!/bin/sh\necho QuickJS version 2025\n")

        let qjs = helpers.appendingPathComponent("qjs")
        try FileManager.default.removeItem(at: qjs)
        try FileManager.default.createSymbolicLink(at: qjs, withDestinationURL: escapedHelper)

        XCTAssertThrowsError(try Toolchain.resolve(bundle: bundle)) { error in
            XCTAssertEqual((error as? DownloadFailure)?.category, .bundledDownloaderUnavailable)
        }
    }

    func testValidatorRunsEveryVersionCommandInOrder() async throws {
        let runner = RecordingProcessRunner()

        _ = try await ToolchainValidator(processRunner: runner).validate(.fixture())

        let commands = await runner.commands()
        XCTAssertEqual(commands.map(\.arguments), [["--version"], ["-version"], ["-version"], ["--help"]])
    }

    func testValidationGateCachesHealthAndForcedValidationRunsCommandsAgain() async throws {
        let runner = RecordingProcessRunner()
        let gate = ToolchainValidationGate(
            toolchain: .fixture(),
            validator: ToolchainValidator(processRunner: runner)
        )

        _ = try await gate.validate(force: false)
        _ = try await gate.validate(force: false)
        let cachedCommandCount = await runner.commands().count
        XCTAssertEqual(cachedCommandCount, 4)

        _ = try await gate.validate(force: true)
        let forcedCommandCount = await runner.commands().count
        XCTAssertEqual(forcedCommandCount, 8)
    }

    func testValidatorAcceptsQuickJSHelpVersionOutputWithExitCodeOne() async throws {
        let runner = RecordingProcessRunner()

        let health = try await ToolchainValidator(processRunner: runner).validate(.fixture())

        XCTAssertEqual(health.quickJSVersion, "2025-01-01")
    }

    func testValidatorRejectsQuickJSHelpOutputWithExitCodeTwo() async {
        let runner = RecordingProcessRunner(mode: .quickJSHelpExitCode(2))

        do {
            _ = try await ToolchainValidator(processRunner: runner).validate(.fixture())
            XCTFail("Expected unavailable downloader failure")
        } catch {
            XCTAssertEqual((error as? DownloadFailure)?.category, .bundledDownloaderUnavailable)
        }
    }

    func testValidatorRejectsMismatchedFFmpegAndFFprobeFamilies() async {
        let runner = RecordingProcessRunner(mode: .mismatchedFFprobe)

        do {
            _ = try await ToolchainValidator(processRunner: runner).validate(.fixture())
            XCTFail("Expected incompatible converter failure")
        } catch {
            XCTAssertEqual((error as? DownloadFailure)?.category, .bundledConverterUnavailable)
        }
    }

    func testValidatorRejectsInvalidQuickJSOutput() async {
        let runner = RecordingProcessRunner(mode: .invalidQuickJS)

        do {
            _ = try await ToolchainValidator(processRunner: runner).validate(.fixture())
            XCTFail("Expected unavailable downloader failure")
        } catch {
            XCTAssertEqual((error as? DownloadFailure)?.category, .bundledDownloaderUnavailable)
        }
    }

    func testValidatorDoesNotExposeRawHelperStderr() async {
        let secret = "raw-helper-stderr-secret"
        let runner = RecordingProcessRunner(mode: .failed(toolName: "ffmpeg", stderr: secret))

        do {
            _ = try await ToolchainValidator(processRunner: runner).validate(.fixture())
            XCTFail("Expected unavailable converter failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .bundledConverterUnavailable)
            XCTAssertFalse(failure.technicalDetail?.contains(secret) ?? false)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSystemProcessLauncherCapturesBothPipesAndExitCode() async throws {
        let executable = try makeScript(
            """
            #!/bin/sh
            i=0
            while [ "$i" -lt 4096 ]; do
                printf 'stdout-%s\\n' "$i"
                printf 'stderr-%s\\n' "$i" >&2
                i=$((i + 1))
            done
            exit 7
            """
        )

        let result = try await SystemProcessLauncher().run(executable: executable, arguments: [])

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.stdout.contains("stdout-4095"))
        XCTAssertTrue(result.stderr.contains("stderr-4095"))
    }

    private func makeBundle(helperNames: [String]) throws -> URL {
        let bundle = try temporaryDirectory().appendingPathComponent("Test.app", isDirectory: true)
        let helpers = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        for name in helperNames {
            try makeExecutable(
                at: helpers.appendingPathComponent(name),
                script: "#!/bin/sh\necho \(name)\n"
            )
        }

        return bundle
    }

    private func makeScript(_ script: String) throws -> URL {
        let executable = try temporaryDirectory().appendingPathComponent("process-fixture")
        try makeExecutable(at: executable, script: script)
        return executable
    }

    private func makeExecutable(at url: URL, script: String) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
