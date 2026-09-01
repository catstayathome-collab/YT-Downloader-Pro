import Foundation

enum MediaURLValidator {
    static func isSupported(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else { return false }

        return ["http", "https"].contains(scheme)
            && components.user == nil
            && components.password == nil
    }

    static func credentialFreeEquivalent(of value: String) -> String? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              ["http", "https"].contains(scheme) else { return nil }

        guard components.user != nil || components.password != nil else {
            return isSupported(value) ? value : nil
        }

        components.user = nil
        components.password = nil
        guard let sanitized = components.string, isSupported(sanitized) else { return nil }
        return sanitized
    }
}
