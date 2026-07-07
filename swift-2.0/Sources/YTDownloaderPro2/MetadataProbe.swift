import Foundation

enum MetadataProbeError: LocalizedError {
    case invalidOutput
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidOutput:
            "Could not read video metadata."
        case .processFailed(let message):
            message.isEmpty ? "Video analysis failed." : message
        }
    }
}

struct MetadataProbe {
    static func analyze(url: String, options: DownloadOptions, toolchain: Toolchain) throws -> VideoAnalysis {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = toolchain.ytDlp
        process.arguments = arguments(url: url, options: options)
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw MetadataProbeError.processFailed(message)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        else {
            throw MetadataProbeError.invalidOutput
        }

        let title = json["title"] as? String ?? "Untitled"
        let formats = json["formats"] as? [[String: Any]] ?? []
        var videoFormats: [FormatOption] = []
        var audioFormats: [FormatOption] = []

        for format in formats {
            let formatID = format["format_id"] as? String ?? ""
            guard !formatID.isEmpty else { continue }

            let ext = format["ext"] as? String ?? "unknown"
            let vcodec = format["vcodec"] as? String ?? "none"
            let acodec = format["acodec"] as? String ?? "none"
            let note = format["format_note"] as? String ?? ""

            let height = numeric(format["height"])
            if vcodec != "none", height > 0 {
                let fps = numeric(format["fps"])
                let fpsLabel = fps > 0 ? " \(Int(fps))fps" : ""
                let label = "\(Int(height))p - \(ext)\(fpsLabel)\(note.isEmpty ? "" : " (\(note))")"
                let priority = height * 10 + (ext == "mp4" ? 5 : 0) + fps / 100
                videoFormats.append(FormatOption(formatID: formatID, label: label, priority: priority))
            }

            if acodec != "none", vcodec == "none" {
                let language = format["language"] as? String ?? "original"
                let abr = numeric(format["abr"]) > 0 ? numeric(format["abr"]) : numeric(format["tbr"])
                let notePriority: Double
                switch note.lowercased() {
                case let value where value.contains("high"):
                    notePriority = 300
                case let value where value.contains("medium"):
                    notePriority = 200
                case let value where value.contains("low"):
                    notePriority = 100
                default:
                    notePriority = 150
                }
                let label = "Audio: \(language)\(note.isEmpty ? "" : " (\(note))") - \(ext)"
                let priority = notePriority + abr + (ext == "m4a" ? 3 : 0)
                audioFormats.append(FormatOption(formatID: formatID, label: label, priority: priority))
            }
        }

        videoFormats.sort { $0.priority > $1.priority }
        audioFormats.sort { $0.priority > $1.priority }

        return VideoAnalysis(url: url, title: title, videoFormats: videoFormats, audioFormats: audioFormats)
    }

    private static func arguments(url: String, options: DownloadOptions) -> [String] {
        var args = [
            "--dump-single-json",
            "--no-warnings",
            "--no-check-certificate",
            "--skip-download"
        ]

        switch options.cookiesMode {
        case .none:
            break
        case .chrome:
            args += ["--cookies-from-browser", "chrome"]
        case .safari:
            args += ["--cookies-from-browser", "safari"]
        }

        args.append(url)
        return args
    }

    private static func numeric(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }
}

struct FileNamer {
    static func uniqueOutputTemplate(directory: String, title: String, targetExtension: String) -> String {
        let safeBase = sanitized(title: title).isEmpty ? "Untitled" : sanitized(title: title)
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var candidate = safeBase
        var counter = 1

        while FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("\(candidate).\(targetExtension)").path) {
            candidate = "\(safeBase) (\(counter))"
            counter += 1
        }

        return directoryURL.appendingPathComponent(candidate).path + ".%(ext)s"
    }

    private static func sanitized(title: String) -> String {
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return title.components(separatedBy: illegal).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
