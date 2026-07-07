import Foundation

struct Toolchain {
    let ytDlp: URL
    let ffmpeg: URL
    let ffprobe: URL

    static func resolve() throws -> Toolchain {
        let helperDirectory = try resolveHelperDirectory()
        return Toolchain(
            ytDlp: try executable(named: "yt-dlp_macos", in: helperDirectory),
            ffmpeg: try executable(named: "ffmpeg", in: helperDirectory),
            ffprobe: try executable(named: "ffprobe", in: helperDirectory)
        )
    }

    static func validate() throws {
        let tools = try resolve()
        try runVersionCheck(tools.ffmpeg)
        try runVersionCheck(tools.ffprobe)
        try runVersionCheck(tools.ytDlp)
    }

    private static func resolveHelperDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["YTDP_HELPER_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let bundleURL = Bundle.main.bundleURL
        let appHelpers = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        if FileManager.default.fileExists(atPath: appHelpers.path) {
            return appHelpers
        }

        let packageTools = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .appendingPathComponent("tools", isDirectory: true)
        if FileManager.default.fileExists(atPath: packageTools.path) {
            return packageTools
        }

        throw ToolchainError.helperDirectoryMissing
    }

    private static func executable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ToolchainError.executableMissing(name)
        }
        return url
    }

    private static func runVersionCheck(_ url: URL) throws {
        let process = Process()
        process.executableURL = url
        process.arguments = url.lastPathComponent == "yt-dlp_macos" ? ["--version"] : ["-version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ToolchainError.versionCheckFailed(url.lastPathComponent)
        }
    }
}

enum ToolchainError: LocalizedError {
    case helperDirectoryMissing
    case executableMissing(String)
    case versionCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperDirectoryMissing:
            "Could not find bundled helper tools."
        case .executableMissing(let name):
            "Missing executable helper: \(name)"
        case .versionCheckFailed(let name):
            "Helper failed version check: \(name)"
        }
    }
}
