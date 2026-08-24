import Foundation

struct Toolchain: Equatable, Sendable {
    let ytDLP: URL
    let ffmpeg: URL
    let ffprobe: URL
    let qjs: URL

    static func resolve(bundle: URL) throws -> Toolchain {
        let helpers = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .standardizedFileURL

        return try Toolchain(
            ytDLP: resolveHelper(named: "yt-dlp_macos", in: helpers),
            ffmpeg: resolveHelper(named: "ffmpeg", in: helpers),
            ffprobe: resolveHelper(named: "ffprobe", in: helpers),
            qjs: resolveHelper(named: "qjs", in: helpers)
        )
    }

    private static func resolveHelper(named name: String, in helpers: URL) throws -> URL {
        let canonicalURL = helpers.appendingPathComponent(name).standardizedFileURL
        let resolvedURL = canonicalURL.resolvingSymlinksInPath().standardizedFileURL

        guard isDescendant(resolvedURL, of: helpers), isExecutableRegularFile(at: resolvedURL) else {
            throw failure(for: name)
        }

        return canonicalURL
    }

    private static func isDescendant(_ child: URL, of directory: URL) -> Bool {
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return child.path.hasPrefix(directoryPath)
    }

    private static func isExecutableRegularFile(at url: URL) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let permissions = attributes[.posixPermissions] as? NSNumber
        else {
            return false
        }

        return permissions.intValue & 0o111 != 0
    }

    static func failure(for helperName: String, exitCode: Int32? = nil) -> DownloadFailure {
        let category: DownloadFailure.Category = switch helperName {
        case "ffmpeg", "ffprobe": .bundledConverterUnavailable
        default: .bundledDownloaderUnavailable
        }
        return DownloadFailure(
            category: category,
            technicalDetail: "The bundled \(helperName) helper is unavailable.",
            toolExitCode: exitCode
        )
    }
}

struct ToolchainHealth: Equatable, Sendable {
    let ytDLPVersion: String
    let ffmpegVersion: String
    let ffprobeVersion: String
    let quickJSVersion: String
}

protocol ToolchainHealthValidating: Sendable {
    func validate(force: Bool) async throws -> ToolchainHealth
}

actor ToolchainValidationGate: ToolchainHealthValidating {
    private struct ValidationOperation {
        let id: UUID
        let task: Task<Result<ToolchainHealth, DownloadFailure>, Never>
    }

    private let toolchain: Toolchain
    private let validator: ToolchainValidator
    private var cachedResult: Result<ToolchainHealth, DownloadFailure>?
    private var operation: ValidationOperation?

    init(toolchain: Toolchain, validator: ToolchainValidator = ToolchainValidator()) {
        self.toolchain = toolchain
        self.validator = validator
    }

    func validate(force: Bool) async throws -> ToolchainHealth {
        if !force, let cachedResult {
            return try cachedResult.get()
        }
        if !force, let operation {
            return try await operation.task.value.get()
        }

        let id = UUID()
        let toolchain = self.toolchain
        let validator = self.validator
        let task = Task<Result<ToolchainHealth, DownloadFailure>, Never> {
            do {
                return .success(try await validator.validate(toolchain))
            } catch let failure as DownloadFailure {
                return .failure(failure)
            } catch {
                return .failure(Toolchain.failure(for: "yt-dlp_macos"))
            }
        }
        operation = ValidationOperation(id: id, task: task)
        let result = await task.value
        if operation?.id == id {
            operation = nil
            cachedResult = result
        }
        return try result.get()
    }
}

struct ToolchainValidator: Sendable {
    private let processRunner: any ProcessRunning

    init(processRunner: any ProcessRunning = SystemProcessLauncher()) {
        self.processRunner = processRunner
    }

    func validate(_ toolchain: Toolchain) async throws -> ToolchainHealth {
        let ytDLP = try await validateVersion(
            executable: toolchain.ytDLP,
            arguments: ["--version"],
            helperName: "yt-dlp_macos",
            recognizes: { Self.ytDLPVersion(from: $0) != nil }
        )
        let ffmpeg = try await validateVersion(
            executable: toolchain.ffmpeg,
            arguments: ["-version"],
            helperName: "ffmpeg",
            recognizes: { Self.ffmpegVersion(from: $0) != nil }
        )
        let ffprobe = try await validateVersion(
            executable: toolchain.ffprobe,
            arguments: ["-version"],
            helperName: "ffprobe",
            recognizes: { Self.ffprobeVersion(from: $0) != nil }
        )
        let qjs = try await validateVersion(
            executable: toolchain.qjs,
            arguments: ["--help"],
            helperName: "qjs",
            acceptedExitCodes: [0, 1],
            recognizes: { $0.contains("QuickJS version") }
        )

        guard
            let ytDLPVersion = Self.ytDLPVersion(from: ytDLP),
            let ffmpegVersion = Self.ffmpegVersion(from: ffmpeg),
            let ffprobeVersion = Self.ffprobeVersion(from: ffprobe),
            let quickJSVersion = Self.quickJSVersion(from: qjs),
            Self.versionFamily(ffmpegVersion) == Self.versionFamily(ffprobeVersion)
        else {
            throw Toolchain.failure(for: "ffmpeg")
        }

        return ToolchainHealth(
            ytDLPVersion: ytDLPVersion,
            ffmpegVersion: ffmpegVersion,
            ffprobeVersion: ffprobeVersion,
            quickJSVersion: quickJSVersion
        )
    }

    private func validateVersion(
        executable: URL,
        arguments: [String],
        helperName: String,
        acceptedExitCodes: Set<Int32> = [0],
        recognizes: (String) -> Bool
    ) async throws -> String {
        let result: ProcessResult
        do {
            result = try await processRunner.run(executable: executable, arguments: arguments)
        } catch {
            throw Toolchain.failure(for: helperName)
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acceptedExitCodes.contains(result.exitCode), !output.isEmpty, recognizes(output) else {
            throw Toolchain.failure(for: helperName, exitCode: result.exitCode)
        }
        return output
    }

    private static func ytDLPVersion(from output: String) -> String? {
        firstMatch(in: output, pattern: #"\b[0-9]{4}\.[0-9]{2}\.[0-9]{2}\b"#)
    }

    private static func ffmpegVersion(from output: String) -> String? {
        firstMatch(in: output, pattern: #"(?i)\bffmpeg version ([0-9]+(?:\.[0-9]+)*)"#, capture: 1)
    }

    private static func ffprobeVersion(from output: String) -> String? {
        firstMatch(in: output, pattern: #"(?i)\bffprobe version ([0-9]+(?:\.[0-9]+)*)"#, capture: 1)
    }

    private static func quickJSVersion(from output: String) -> String? {
        firstMatch(in: output, pattern: #"QuickJS version ([^\r\n]+)"#, capture: 1)
    }

    private static func versionFamily(_ version: String) -> String {
        version.split(separator: ".", maxSplits: 1).first.map(String.init) ?? version
    }

    private static func firstMatch(in string: String, pattern: String, capture: Int = 0) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = expression.firstMatch(in: string, range: range) else { return nil }
        guard let matchRange = Range(match.range(at: capture), in: string) else { return nil }
        return String(string[matchRange])
    }
}
