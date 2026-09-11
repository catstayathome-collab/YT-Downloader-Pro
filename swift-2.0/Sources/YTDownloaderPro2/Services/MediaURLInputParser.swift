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
                  let normalized = normalized(candidate) else {
                rejectedCount += 1
                continue
            }

            if seen.insert(normalized).inserted {
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
