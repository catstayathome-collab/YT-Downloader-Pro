import Foundation

// Actual ffprobe output is authoritative; analysis labels and file extensions are not.
struct ProbedMedia: Decodable, Sendable {
    struct Stream: Decodable, Sendable {
        let index: Int
        let codecName: String?
        let codecType: String
        let codecTag: String?
        let width: Int?
        let height: Int?
        let pixelFormat: String?
        let sampleAspectRatio: String?
        let averageFrameRate: String?
        let nominalFrameRate: String?
        let timeBase: String?
        let duration: String?
        let declaredFrameCount: String?
        let readFrameCount: String?
        var frameCount: String? { readFrameCount ?? declaredFrameCount }
        let channels: Int?
        let sampleRate: String?
        let colorSpace: String?
        let colorTransfer: String?
        let colorPrimaries: String?
        let colorRange: String?
        let disposition: [String: Int]?
        let tags: [String: String]?
        let sideData: [[String: ProbeValue]]?

        enum CodingKeys: String, CodingKey {
            case index, width, height, duration, channels, disposition, tags
            case codecName = "codec_name", codecType = "codec_type", codecTag = "codec_tag_string"
            case pixelFormat = "pix_fmt", sampleAspectRatio = "sample_aspect_ratio"
            case averageFrameRate = "avg_frame_rate", nominalFrameRate = "r_frame_rate", timeBase = "time_base"
            case declaredFrameCount = "nb_frames", readFrameCount = "nb_read_frames", sampleRate = "sample_rate"
            case colorSpace = "color_space", colorTransfer = "color_transfer"
            case colorPrimaries = "color_primaries", colorRange = "color_range", sideData = "side_data_list"
        }

        var isArtwork: Bool { disposition?["attached_pic"] == 1 }
        var rotation: Double {
            let matrix = sideData?.first { $0["side_data_type"] == .string("Display Matrix") }
            if let matrix { return matrix["rotation"]?.number ?? .nan }
            if let tag = tags?["rotate"] { return Double(tag) ?? .nan }
            return 0
        }
        var displayWidth: Int? { abs(rotation.truncatingRemainder(dividingBy: 180)) == 90 ? height : width }
        var displayHeight: Int? { abs(rotation.truncatingRemainder(dividingBy: 180)) == 90 ? width : height }
        var isHDR: Bool {
            ["smpte2084", "arib-std-b67"].contains(colorTransfer ?? "") || !hdrMetadata.isEmpty
        }
        var hdrMetadata: [[String: ProbeValue]] {
            (sideData ?? []).filter {
                guard case let .string(type) = $0["side_data_type"] else { return false }
                return type != "Display Matrix" && type != "CPB properties"
            }
        }
        var knownSDR: Bool {
            colorSpace == "bt709" && colorTransfer == "bt709" && colorPrimaries == "bt709" &&
            ["tv", "pc"].contains(colorRange ?? "") && !isHDR
        }
        var quickTimeCompatible: Bool {
            if codecName == "h264" { return pixelFormat == "yuv420p" && !isHDR }
            guard codecName == "hevc", codecTag == "hvc1",
                  ["yuv420p", "yuv420p10le"].contains(pixelFormat ?? "") else { return false }
            let knownHDRMetadata = hdrMetadata.allSatisfy {
                $0["side_data_type"] == .string("Mastering display metadata") ||
                $0["side_data_type"] == .string("Content light level metadata")
            }
            return !isHDR || (knownHDRMetadata && pixelFormat == "yuv420p10le" && colorPrimaries == "bt2020" &&
                colorSpace == "bt2020nc" && ["smpte2084", "arib-std-b67"].contains(colorTransfer ?? ""))
        }
    }

    struct Container: Decodable, Sendable {
        let name: String?
        let duration: String?
        enum CodingKeys: String, CodingKey { case name = "format_name", duration }
    }

    let streams: [Stream]
    let format: Container?
    var primaryVideo: Stream? { streams.first { $0.codecType == "video" && !$0.isArtwork } }
    var primaryAudio: Stream? { streams.first { $0.codecType == "audio" } }
    var subtitles: [Stream] { streams.filter { $0.codecType == "subtitle" } }
    var artwork: [Stream] { streams.filter(\.isArtwork) }
    var duration: Double? { (primaryVideo?.duration ?? format?.duration).flatMap(Double.init) }
}

// Keep all HDR side-data fields, including nested Dolby Vision/HDR10+ payloads.
indirect enum ProbeValue: Decodable, Equatable, Sendable {
    case string(String), number(Double), object([String: ProbeValue]), array([ProbeValue]), boolean(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let object = try? value.decode([String: ProbeValue].self) { self = .object(object) }
        else { self = .array(try value.decode([ProbeValue].self)) }
    }
    var number: Double? { if case let .number(value) = self { value } else { nil } }
}

enum MP4OutputPlanningError: Error, Equatable, Sendable {
    case invalidProbe
    case unsupportedStreams
    case unsupportedColorConversion
    case encoderUnavailable
    case encoderProbeFailed
    case outputValidationFailed
}

enum MP4VideoEncoder: String, Hashable, Sendable {
    case videoToolbox = "hevc_videotoolbox"
    case libx265
    var arguments: [String] {
        switch self {
        case .videoToolbox: ["-c:v:0", rawValue, "-q:v:0", "65", "-allow_sw", "0", "-profile:v:0", "main"]
        case .libx265: ["-c:v:0", rawValue, "-crf", "20", "-preset", "medium"]
        }
    }
}

struct MP4EncoderCapabilities: Sendable {
    private(set) var verifiedEncoders: Set<MP4VideoEncoder> = []

    // The caller owns the synthetic subprocess; a listing alone cannot grant capability.
    mutating func recordProbe(encoder: MP4VideoEncoder, exitCode: Int32, source: ProbedMedia, output: ProbedMedia) throws {
        guard exitCode == 0, output.primaryVideo?.codecName == "hevc" else {
            throw MP4OutputPlanningError.encoderProbeFailed
        }
        try MP4OutputPlanner().validate(output: output, source: source, mode: .quickTimeCompatible)
        verifiedEncoders.insert(encoder)
    }
}

struct MP4OutputPlan: Sendable {
    enum VideoAction: Equatable, Sendable { case copy, encode(MP4VideoEncoder) }
    enum AudioAction: Equatable, Sendable { case copy, aac, absent }
    let videoAction: VideoAction
    let audioAction: AudioAction
    let source: ProbedMedia
    let mode: MP4OutputMode

    // Pure command construction. The runner supplies job-owned paths and handles publication.
    func arguments(input: URL, output: URL) -> [String] {
        guard let video = source.primaryVideo else { return [] }
        var args = ["-hide_banner", "-nostdin", "-n", "-noautorotate", "-i", input.path,
                    "-map", "0:\(video.index)"]
        if let audio = source.primaryAudio { args += ["-map", "0:\(audio.index)"] }
        for stream in source.subtitles + source.artwork { args += ["-map", "0:\(stream.index)"] }
        args += ["-map_metadata", "0", "-map_chapters", "0", "-c", "copy"]
        switch videoAction {
        case .copy: break
        case let .encode(encoder):
            args += encoder.arguments + ["-pix_fmt:v:0", "yuv420p", "-fps_mode:v:0", "passthrough",
                "-colorspace:v:0", "bt709", "-color_trc:v:0", "bt709", "-color_primaries:v:0", "bt709",
                "-color_range:v:0", video.colorRange ?? "tv"]
        }
        if video.codecName == "hevc" || videoAction != .copy { args += ["-tag:v:0", "hvc1"] }
        if audioAction == .aac { args += ["-c:a:0", "aac", "-b:a:0", "192k"] }
        for (index, subtitle) in source.subtitles.enumerated() where subtitle.codecName != "mov_text" {
            args += ["-c:s:\(index)", "mov_text"]
        }
        for index in source.artwork.indices { args += ["-disposition:v:\(index + 1)", "attached_pic"] }
        return args + ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", "-f", "mp4", output.path]
    }
}

struct MP4OutputPlanner: Sendable {
    func plan(media: ProbedMedia, mode: MP4OutputMode, capabilities: MP4EncoderCapabilities) throws -> MP4OutputPlan {
        let video = try checkedVideo(media)
        let videoAction: MP4OutputPlan.VideoAction
        let audioAction: MP4OutputPlan.AudioAction
        if mode == .originalEncoding {
            guard ["h264", "hevc", "vp9", "av1", "mpeg4"].contains(video.codecName ?? ""),
                  media.primaryAudio.map({ ["aac", "opus", "mp3", "alac", "ac3", "eac3"].contains($0.codecName ?? "") }) ?? true else {
                throw MP4OutputPlanningError.unsupportedStreams
            }
            videoAction = .copy
            audioAction = media.primaryAudio == nil ? .absent : .copy
        } else {
            if video.quickTimeCompatible { videoAction = .copy }
            else {
                guard video.knownSDR, video.pixelFormat == "yuv420p" else {
                    throw MP4OutputPlanningError.unsupportedColorConversion
                }
                if capabilities.verifiedEncoders.contains(.videoToolbox) { videoAction = .encode(.videoToolbox) }
                else if capabilities.verifiedEncoders.contains(.libx265) { videoAction = .encode(.libx265) }
                else { throw MP4OutputPlanningError.encoderUnavailable }
            }
            audioAction = media.primaryAudio.map { $0.codecName == "aac" ? .copy : .aac } ?? .absent
        }
        return MP4OutputPlan(videoAction: videoAction, audioAction: audioAction, source: media, mode: mode)
    }

    func validate(output: ProbedMedia, source: ProbedMedia, mode: MP4OutputMode) throws {
        let before = try checkedVideo(source)
        let after = try checkedVideo(output)
        guard output.format?.name?.split(separator: ",").contains("mp4") == true,
              before.width == after.width, before.height == after.height,
              normalizedRotation(before.rotation) == normalizedRotation(after.rotation),
              (before.sampleAspectRatio ?? "1:1") == (after.sampleAspectRatio ?? "1:1"),
              before.colorSpace == after.colorSpace, before.colorTransfer == after.colorTransfer,
              before.colorPrimaries == after.colorPrimaries, before.colorRange == after.colorRange,
              before.hdrMetadata == after.hdrMetadata else { throw MP4OutputPlanningError.outputValidationFailed }
        if let duration = source.duration, duration.isFinite, duration > 0 {
            guard let actual = output.duration, actual.isFinite, abs(actual - duration) <= 0.15 else {
                throw MP4OutputPlanningError.outputValidationFailed
            }
        }
        if let frames = before.frameCount.flatMap(Int.init) {
            guard after.frameCount.flatMap(Int.init) == frames else { throw MP4OutputPlanningError.outputValidationFailed }
        }
        // Matroska may report nominal rate as average for VFR. Compare frame counts
        // and duration above; exact timestamps are exercised by tool integration tests.
        if frameRate(before.averageFrameRate) != nil {
            guard frameRate(after.averageFrameRate) != nil else {
                throw MP4OutputPlanningError.outputValidationFailed
            }
        }
        guard source.subtitles.count == output.subtitles.count, source.artwork.count == output.artwork.count else {
            throw MP4OutputPlanningError.outputValidationFailed
        }
        for (before, after) in zip(source.subtitles, output.subtitles) {
            guard after.codecName == "mov_text", before.tags?["language"] == after.tags?["language"] else {
                throw MP4OutputPlanningError.outputValidationFailed
            }
        }
        for (before, after) in zip(source.artwork, output.artwork) {
            guard before.codecName == after.codecName, before.width == after.width, before.height == after.height else {
                throw MP4OutputPlanningError.outputValidationFailed
            }
        }
        if let audio = source.primaryAudio {
            guard let actual = output.primaryAudio, audio.channels == actual.channels,
                  audio.sampleRate == actual.sampleRate,
                  actual.codecName == (mode == .originalEncoding ? audio.codecName : "aac") else {
                throw MP4OutputPlanningError.outputValidationFailed
            }
        } else if output.primaryAudio != nil { throw MP4OutputPlanningError.outputValidationFailed }
        if mode == .quickTimeCompatible {
            guard after.quickTimeCompatible else { throw MP4OutputPlanningError.outputValidationFailed }
        } else {
            guard before.codecName == after.codecName, before.pixelFormat == after.pixelFormat else {
                throw MP4OutputPlanningError.outputValidationFailed
            }
        }
    }

    private func checkedVideo(_ media: ProbedMedia) throws -> ProbedMedia.Stream {
        guard let video = media.primaryVideo, let width = video.width, let height = video.height,
              width > 0, height > 0, video.rotation.isFinite,
              video.rotation.truncatingRemainder(dividingBy: 90) == 0,
              media.duration.map({ $0.isFinite && $0 > 0 }) ?? true,
              Set(media.streams.map(\.index)).count == media.streams.count,
              media.streams.allSatisfy({ $0.index >= 0 && $0.codecName != nil }) else {
            throw MP4OutputPlanningError.invalidProbe
        }
        guard media.streams.filter({ $0.codecType == "video" && !$0.isArtwork }).count == 1,
              media.streams.filter({ $0.codecType == "audio" }).count <= 1,
              media.streams.allSatisfy({ ["video", "audio", "subtitle"].contains($0.codecType) }),
              media.subtitles.allSatisfy({ ["mov_text", "subrip", "webvtt"].contains($0.codecName ?? "") }),
              media.artwork.allSatisfy({ ["mjpeg", "png"].contains($0.codecName ?? "") }) else {
            throw MP4OutputPlanningError.unsupportedStreams
        }
        if let audio = media.primaryAudio {
            guard let channels = audio.channels, channels > 0,
                  let rate = audio.sampleRate.flatMap(Int.init), rate > 0 else {
                throw MP4OutputPlanningError.invalidProbe
            }
        }
        return video
    }

    private func normalizedRotation(_ value: Double) -> Double { (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
    private func frameRate(_ value: String?) -> Double? {
        guard let parts = value?.split(separator: "/"), parts.count == 2,
              let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator > 0, numerator > 0 else { return nil }
        return numerator / denominator
    }
}
