import Foundation

struct YouTubeStrategy: Sendable {
    private static let initialClient = "web_embedded"

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

    func downloadArguments(job: DownloadJob, toolchain: Toolchain, attempt: Int, featurePolicy: FeaturePolicyContext = .publicCompatibility, sourceTemplate: String? = nil) -> [String] {
        var arguments = [
            "--no-warnings",
            "--continue",
            "--no-overwrites",
            "--progress",
            "--newline",
            "--ffmpeg-location",
            toolchain.ffmpeg.deletingLastPathComponent().path,
            "--format",
            selectedFormat(for: job.options.normalizedForExecution(), featurePolicy: featurePolicy),
            "--output",
            sourceTemplate ?? outputTemplate(for: job),
            "--print",
            "before_dl:ytdp:phase|downloading",
            "--progress-template",
            "download:ytdp:progress|%(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template",
            "postprocess:ytdp:phase|\(postprocessPhase(for: job.options.outputKind))",
            "--print",
            "after_move:ytdp:filepath|%(filepath)s"
        ]

        if job.options.outputKind == .mp4 {
            // A progressive single-file format does not run yt-dlp's merger.
            arguments += ["--merge-output-format", "mp4", "--remux-video", "mp4"]
        } else {
            arguments += ["--extract-audio", "--audio-format", "mp3"]
        }

        arguments += commonArguments(options: job.options, attempt: attempt, toolchain: toolchain, client: job.options.clientStrategy)
        arguments.append(job.sourceURL)
        return arguments
    }

    private func commonArguments(options: DownloadOptions, attempt: Int, toolchain: Toolchain? = nil, client: YouTubeClientStrategy? = nil) -> [String] {
        let options = options.normalizedForExecution()
        let selectedToolchain = toolchain ?? self.toolchain
        var arguments = [
            "--js-runtimes",
            "quickjs:\(selectedToolchain.qjs.path)"
        ]
        if (client ?? analysisClient(options: options, attempt: attempt)) == .webEmbedded {
            arguments += ["--extractor-args", "youtube:player_client=\(Self.initialClient)"]
        }
        return arguments + subtitleArguments(for: options) + metadataArguments(for: options) + cookieArguments(for: options.cookies)
    }

    func analysisClient(options: DownloadOptions, attempt: Int) -> YouTubeClientStrategy {
        options.cookies != .none || attempt == 0 ? .webEmbedded : .defaultClient
    }

    private func selectedFormat(for options: DownloadOptions, featurePolicy: FeaturePolicyContext) -> String {
        switch options.outputKind {
        case .mp4:
            let videoID = formatID(from: options.videoQuality)
            let audioID = formatID(from: options.audioQuality)
            let heightFilter: String
            if case let .enforced(policy) = featurePolicy,
               case let .limited(limit) = policy.videoHeightPolicy {
                heightFilter = "[height<=\(limit)]"
            } else {
                heightFilter = ""
            }
            switch (videoID, audioID) {
            case let (videoID?, audioID?):
                return "\(videoID)\(heightFilter)+\(audioID)"
            case let (videoID?, nil):
                return "\(videoID)\(heightFilter)+bestaudio"
            case let (nil, audioID?):
                return "bestvideo\(heightFilter)+\(audioID)"
            case (nil, nil):
                return "bestvideo\(heightFilter)+bestaudio/best\(heightFilter)"
            }
        case .mp3:
            let audioID = formatID(from: options.audioQuality) ?? "bestaudio"
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

    private func postprocessPhase(for outputKind: OutputKind) -> String {
        // yt-dlp exposes a postprocess template but no merge-only hook.
        outputKind == .mp4 ? "merging" : "postprocessing"
    }

    private func subtitleArguments(for options: DownloadOptions) -> [String] {
        guard options.subtitleMode != .none,
              let language = options.subtitleLanguage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty,
              language.caseInsensitiveCompare("live_chat") != .orderedSame else {
            return []
        }

        var arguments: [String]
        switch options.subtitleSource {
        case .official:
            arguments = ["--write-subs"]
        case .automatic:
            arguments = ["--write-auto-subs"]
        case nil:
            arguments = ["--write-subs", "--write-auto-subs"]
        }
        arguments += ["--sub-langs", language, "--sub-format", "srt"]
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
