import Foundation
@testable import YTDownloaderPro2

extension Toolchain {
    static func fixture(
        ytDLP: URL = URL(fileURLWithPath: "/tmp/yt-dlp_macos"),
        ffmpeg: URL = URL(fileURLWithPath: "/tmp/ffmpeg"),
        ffprobe: URL = URL(fileURLWithPath: "/tmp/ffprobe"),
        qjs: URL = URL(fileURLWithPath: "/tmp/qjs")
    ) -> Toolchain {
        Toolchain(ytDLP: ytDLP, ffmpeg: ffmpeg, ffprobe: ffprobe, qjs: qjs)
    }
}

actor RecordingProcessRunner: ProcessRunning {
    struct Command: Equatable, Sendable {
        let executable: URL
        let arguments: [String]
    }

    enum Mode: Sendable {
        case healthy
        case failed(toolName: String, stderr: String)
        case mismatchedFFprobe
        case invalidQuickJS
    }

    private let mode: Mode
    private var recordedCommands: [Command] = []

    init(mode: Mode = .healthy) {
        self.mode = mode
    }

    func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        recordedCommands.append(Command(executable: executable, arguments: arguments))

        if case let .failed(toolName, stderr) = mode, executable.lastPathComponent == toolName {
            return ProcessResult(exitCode: 1, stdout: "", stderr: stderr)
        }

        switch executable.lastPathComponent {
        case "yt-dlp_macos":
            return ProcessResult(exitCode: 0, stdout: "2025.01.01\n", stderr: "")
        case "ffmpeg":
            return ProcessResult(exitCode: 0, stdout: "ffmpeg version 7.1 Copyright\n", stderr: "")
        case "ffprobe":
            let version: String
            if case .mismatchedFFprobe = mode {
                version = "6.1"
            } else {
                version = "7.1"
            }
            return ProcessResult(exitCode: 0, stdout: "ffprobe version \(version) Copyright\n", stderr: "")
        case "qjs":
            let output: String
            if case .invalidQuickJS = mode {
                output = "JavaScript runtime\n"
            } else {
                output = "QuickJS version 2025-01-01\n"
            }
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        default:
            throw NSError(domain: "RecordingProcessRunner", code: 1)
        }
    }

    func commands() -> [Command] {
        recordedCommands
    }
}
