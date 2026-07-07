import Foundation

@MainActor
final class DownloadRunner {
    private var processes: [UUID: Process] = [:]

    func start(job: DownloadJob, onUpdate: @escaping (DownloadJob) -> Void) {
        var runningJob = job
        runningJob.status = .downloading
        runningJob.updatedAt = Date()
        onUpdate(runningJob)

        Task.detached {
            do {
                let toolchain = try Toolchain.resolve()
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.executableURL = toolchain.ytDlp
                process.arguments = self.arguments(for: runningJob, toolchain: toolchain)
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                await MainActor.run {
                    self.processes[runningJob.id] = process
                }

                let parser = ProgressParser(job: runningJob, onUpdate: onUpdate)
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    parser.consume(data: handle.availableData)
                }
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    parser.consume(data: handle.availableData)
                }

                try process.run()
                process.waitUntilExit()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                await MainActor.run {
                    self.processes[runningJob.id] = nil
                    var finished = parser.currentJob
                    finished.updatedAt = Date()
                    if process.terminationStatus == 0 {
                        finished.status = .completed
                        finished.progress = 1
                        finished.speed = "--"
                    } else if finished.status != .paused && finished.status != .cancelled {
                        finished.status = .failed
                        finished.error = finished.error ?? "yt-dlp exited with code \(process.terminationStatus)"
                    }
                    onUpdate(finished)
                }
            } catch {
                await MainActor.run {
                    runningJob.status = .failed
                    runningJob.error = error.localizedDescription
                    runningJob.updatedAt = Date()
                    onUpdate(runningJob)
                }
            }
        }
    }

    func pause(_ id: UUID, onUpdate: (DownloadStatus) -> Void) {
        processes[id]?.terminate()
        processes[id] = nil
        onUpdate(.paused)
    }

    func cancel(_ id: UUID, onUpdate: (DownloadStatus) -> Void) {
        processes[id]?.terminate()
        processes[id] = nil
        onUpdate(.cancelled)
    }

    private nonisolated func arguments(for job: DownloadJob, toolchain: Toolchain) -> [String] {
        var args = [
            "--newline",
            "--continue",
            "--progress-template", "download:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._total_bytes_str)s",
            "--ffmpeg-location", toolchain.ffmpeg.deletingLastPathComponent().path,
            "--paths", job.options.outputDirectory,
            "--output", "%(title).200B.%(ext)s"
        ]

        switch job.options.cookiesMode {
        case .none:
            break
        case .chrome:
            args += ["--cookies-from-browser", "chrome"]
        case .safari:
            args += ["--cookies-from-browser", "safari"]
        }

        if job.options.audioOnly || job.options.format == .mp3 {
            args += ["--extract-audio", "--audio-format", "mp3", "--audio-quality", "192K"]
        } else {
            args += ["--merge-output-format", "mp4", "--format", job.options.quality == "best" ? "bv*+ba/b" : job.options.quality]
        }

        switch job.options.subtitleMode {
        case .none:
            break
        case .download:
            args += ["--write-subs", "--write-auto-subs"]
        case .embed:
            args += ["--write-subs", "--write-auto-subs", "--embed-subs"]
        }

        if job.options.embedThumbnail {
            args += ["--embed-thumbnail", "--embed-metadata"]
        }

        args.append(job.url)
        return args
    }
}

final class ProgressParser {
    private(set) var currentJob: DownloadJob
    private let onUpdate: (DownloadJob) -> Void

    init(job: DownloadJob, onUpdate: @escaping (DownloadJob) -> Void) {
        currentJob = job
        self.onUpdate = onUpdate
    }

    func consume(data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            parse(String(line))
        }
    }

    private func parse(_ line: String) {
        if line.contains("[Merger]") || line.contains("Merging formats") {
            currentJob.status = .merging
        }

        if line.hasPrefix("download:") {
            let fields = line.replacingOccurrences(of: "download:", with: "").split(separator: "|", omittingEmptySubsequences: false)
            if let percentField = fields.first {
                currentJob.progress = ProgressParser.parsePercent(String(percentField))
            }
            if fields.count > 1 {
                currentJob.speed = String(fields[1]).trimmingCharacters(in: .whitespaces)
            }
        } else if line.lowercased().contains("error") {
            currentJob.error = line
        }

        currentJob.updatedAt = Date()
        DispatchQueue.main.async {
            self.onUpdate(self.currentJob)
        }
    }

    private static func parsePercent(_ text: String) -> Double {
        let cleaned = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        return min(max((Double(cleaned) ?? 0) / 100, 0), 1)
    }
}
