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
}
