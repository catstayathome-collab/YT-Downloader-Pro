import Foundation

struct MediaURLInputParseResult: Equatable, Sendable {
    let urls: [String]
    let rejectedCount: Int
    let duplicateCount: Int
}

enum MediaURLInputParser {
    static func parse(_ input: String) -> MediaURLInputParseResult {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return MediaURLInputParseResult(urls: [], rejectedCount: 0, duplicateCount: 0)
        }

        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = detector.matches(in: input, options: [], range: range)
        var urls: [String] = []
        var seen: Set<String> = []
        var rejectedCount = 0
        var duplicateCount = 0

        for match in matches {
            guard let candidate = match.url?.absoluteString,
                  MediaURLValidator.isSupported(candidate),
                  let normalized = normalized(candidate),
                  let key = deduplicationKey(for: normalized) else {
                rejectedCount += 1
                continue
            }

            if seen.insert(key).inserted {
                urls.append(normalized)
            } else {
                duplicateCount += 1
            }
        }

        return MediaURLInputParseResult(
            urls: urls,
            rejectedCount: rejectedCount,
            duplicateCount: duplicateCount
        )
    }

    static func deduplicationKey(for value: String) -> String? {
        guard let normalized = normalized(value),
              let components = URLComponents(string: normalized),
              let host = components.host?.lowercased() else { return nil }

        let youtubeHosts: Set<String> = [
            "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
            "youtube-nocookie.com", "www.youtube-nocookie.com"
        ]
        let query = components.queryItems ?? []
        if youtubeHosts.contains(host),
           let playlistID = query.first(where: { $0.name == "list" })?.value?.nonEmpty {
            return "youtube:playlist:\(playlistID)"
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        let videoID: String?
        if host == "youtu.be" {
            videoID = pathParts.first?.nonEmpty
        } else if youtubeHosts.contains(host) {
            if components.path == "/watch" {
                videoID = query.first(where: { $0.name == "v" })?.value?.nonEmpty
            } else if let first = pathParts.first,
                      ["embed", "live", "shorts"].contains(first) {
                videoID = pathParts.dropFirst().first?.nonEmpty
            } else {
                videoID = nil
            }
        } else {
            videoID = nil
        }
        if let videoID {
            return "youtube:video:\(videoID)"
        }
        return normalized
    }

    private static func normalized(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme,
              let host = components.host else { return nil }
        components.scheme = scheme.lowercased()
        components.host = host.lowercased()
        components.fragment = nil
        guard let normalized = components.string,
              MediaURLValidator.isSupported(normalized) else { return nil }
        return normalized
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
