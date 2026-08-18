import Foundation

struct YouTubeStrategy: Sendable {
    private static let initialClient = "web_embedded"
    private static let uncookiedFallbackClient = "tv"

    private let toolchain: Toolchain

    init(toolchain: Toolchain) {
        self.toolchain = toolchain
    }

    func analysisArguments(url: String, options: DownloadOptions, attempt: Int) -> [String] {
        [
            "--dump-single-json",
            "--skip-download",
            "--no-warnings"
        ] + commonArguments(options: options, attempt: attempt) + [url]
    }

    func maximumAttempts(for options: DownloadOptions) -> Int {
        options.cookies == .none ? 2 : 1
    }

    func downloadArguments(job: DownloadJob, toolchain: Toolchain, attempt: Int) -> [String] {
        var arguments = [
            "--no-warnings",
            "--continue",
            "--no-overwrites",
            "--ffmpeg-location",
            toolchain.ffmpeg.deletingLastPathComponent().path,
            "--format",
            selectedFormat(for: job.options),
            "--output",
            outputTemplate(for: job),
            "--progress-template",
            "download:ytdp:progress|%(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template",
            "postprocess:ytdp:phase|%(progress._default_template)s",
            "--print",
            "after_move:ytdp:filepath|%(filepath)s"
        ]

        if job.options.outputKind == .mp4 {
            arguments += ["--merge-output-format", "mp4"]
        } else {
            arguments += ["--extract-audio", "--audio-format", "mp3"]
        }

        arguments += commonArguments(options: job.options, attempt: attempt)
        arguments.append(job.sourceURL)
        return arguments
    }

    private func commonArguments(options: DownloadOptions, attempt: Int) -> [String] {
        [
            "--js-runtimes",
            "quickjs:\(toolchain.qjs.path)",
            "--extractor-args",
            "youtube:player_client=\(client(for: options, attempt: attempt))"
        ] + subtitleArguments(for: options) + metadataArguments(for: options) + cookieArguments(for: options.cookies)
    }

    private func client(for options: DownloadOptions, attempt: Int) -> String {
        guard options.cookies == .none else {
            return Self.initialClient
        }
        return attempt == 0 ? Self.initialClient : Self.uncookiedFallbackClient
    }

    private func selectedFormat(for options: DownloadOptions) -> String {
        let audioID = formatID(from: options.audioQuality) ?? "bestaudio"

        switch options.outputKind {
        case .mp4:
            let videoID = formatID(from: options.videoQuality) ?? "bestvideo*"
            let fallback = options.videoQuality == .best && options.audioQuality == .best ? "/best" : ""
            return "\(videoID)+\(audioID)\(fallback)"
        case .mp3:
            return options.audioQuality == .best ? "bestaudio/best" : audioID
        }
    }

    private func formatID(from quality: VideoQuality) -> String? {
        if case let .format(id, _) = quality {
            return id
        }
        return nil
    }

    private func formatID(from quality: AudioQuality) -> String? {
        if case let .format(id, _) = quality {
            return id
        }
        return nil
    }

    private func outputTemplate(for job: DownloadJob) -> String {
        let directory: URL
        if let outputURL = job.outputURL {
            directory = outputURL.deletingLastPathComponent()
        } else if let displayPath = job.options.outputDirectoryDisplayPath {
            directory = URL(fileURLWithPath: displayPath, isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
        }

        let basename: String
        if let reserved = job.reservedOutputBasename, !reserved.isEmpty {
            basename = reserved
        } else if let outputURL = job.outputURL {
            basename = outputURL.deletingPathExtension().lastPathComponent
        } else {
            basename = job.id.uuidString
        }

        return directory.appendingPathComponent("\(basename).%(ext)s").path
    }

    private func subtitleArguments(for options: DownloadOptions) -> [String] {
        guard options.subtitleMode != .none else { return [] }

        var arguments = ["--write-subs"]
        if let language = options.subtitleLanguage, !language.isEmpty {
            arguments += ["--sub-langs", language]
        }
        if options.subtitleMode == .embed {
            arguments.append("--embed-subs")
        }
        return arguments
    }

    private func metadataArguments(for options: DownloadOptions) -> [String] {
        var arguments: [String] = []
        if options.embedThumbnail {
            arguments.append("--embed-thumbnail")
        }
        if options.embedMetadata {
            arguments.append("--embed-metadata")
        }
        return arguments
    }

    private func cookieArguments(for mode: CookieMode) -> [String] {
        switch mode {
        case .none:
            []
        case .chrome:
            ["--cookies-from-browser", "chrome"]
        case .safari:
            ["--cookies-from-browser", "safari"]
        }
    }
}
