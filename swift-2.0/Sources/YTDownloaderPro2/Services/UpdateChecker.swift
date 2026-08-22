import Foundation

struct MacOSUpdateManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let platform: String
    let latestVersion: String
    let minimumMacOS: String
    let releaseURL: URL
    let downloadURL: URL
    let sha256: String
    let publishedAt: String
    let releaseNotes: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case platform
        case latestVersion = "latest_version"
        case minimumMacOS = "minimum_macos"
        case releaseURL = "release_url"
        case downloadURL = "download_url"
        case sha256
        case publishedAt = "published_at"
        case releaseNotes = "release_notes"
    }
}

enum UpdateCheckFailure: Error, Equatable, Sendable {
    case wrongPlatformManifest
    case invalidManifest
    case invalidVersion
    case insecureURL
    case invalidChecksum
    case invalidMinimumMacOS
    case invalidResponse
    case silentTransient
    case actionableNetwork
}

enum UpdateResult: Equatable, Sendable {
    case upToDate
    case available(MacOSUpdateManifest)
    case unsupportedOS(MacOSUpdateManifest)
    case failed(UpdateCheckFailure)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

protocol UpdateSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UpdateSession {}

protocol UpdateChecking: Sendable {
    func check(manual: Bool) async -> UpdateResult
}

/// A strict SemVer 2.0 value. Build metadata is validated but excluded from precedence.
struct SemanticVersion: Comparable, Sendable {
    private let major: String
    private let minor: String
    private let patch: String
    private let prerelease: [String]

    init?(_ source: String) {
        let versionAndBuild = source.split(separator: "+", omittingEmptySubsequences: false)
        guard versionAndBuild.count <= 2,
              !versionAndBuild[0].isEmpty,
              versionAndBuild.dropFirst().allSatisfy({ Self.validIdentifiers(String($0), prerelease: false) }) else {
            return nil
        }

        let coreAndPrerelease = versionAndBuild[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !coreAndPrerelease[0].isEmpty else { return nil }
        let core = coreAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.parseCoreNumber(core[0]),
              let minor = Self.parseCoreNumber(core[1]),
              let patch = Self.parseCoreNumber(core[2]) else {
            return nil
        }

        let prerelease: [String]
        if coreAndPrerelease.count == 2 {
            let value = String(coreAndPrerelease[1])
            guard Self.validIdentifiers(value, prerelease: true) else { return nil }
            prerelease = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        } else {
            prerelease = []
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for (left, right) in zip([lhs.major, lhs.minor, lhs.patch], [rhs.major, rhs.minor, rhs.patch])
            where left != right {
            return Self.numericIdentifierPrecedes(left, right)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftIsNumeric = Self.isASCIINumeric(left)
            let rightIsNumeric = Self.isASCIINumeric(right)
            switch (leftIsNumeric, rightIsNumeric) {
            case (true, true):
                return Self.numericIdentifierPrecedes(left, right)
            case (true, false):
                return true
            case (false, true):
                return false
            case (false, false):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func parseCoreNumber(_ value: Substring) -> String? {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && $0.isNumber }),
              value.count == 1 || value.first != "0" else {
            return nil
        }
        return String(value)
    }

    private static func validIdentifiers(_ value: String, prerelease: Bool) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                return false
            }
            if prerelease,
               identifier.allSatisfy({ $0.isASCII && $0.isNumber }),
               identifier.count > 1,
               identifier.first == "0" {
                return false
            }
            return true
        }
    }

    private static func isASCIINumeric(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isNumber })
    }

    private static func numericIdentifierPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }
}

struct UpdateChecker: UpdateChecking, Sendable {
    /// Bounds the GitHub Contents envelope before JSON or base64 decoding.
    static let maximumResponseBytes = 192 * 1_024
    /// Bounds the decoded platform manifest, including release notes.
    static let maximumDecodedManifestBytes = 96 * 1_024
    static let publicManifestURL = URL(
        string: "https://api.github.com/repos/catstayathome-collab/YT-Downloader-Pro/contents/updates/macos.json?ref=main"
    )!

    private struct ContentsEnvelope: Decodable {
        let encoding: String
        let content: String
    }

    private let manifestURL: URL
    private let currentVersion: String
    private let currentMacOSVersion: String
    private let session: any UpdateSession

    init(
        manifestURL: URL,
        currentVersion: String,
        currentMacOSVersion: String,
        session: any UpdateSession
    ) {
        self.manifestURL = manifestURL
        self.currentVersion = currentVersion
        self.currentMacOSVersion = currentMacOSVersion
        self.session = session
    }

    static func live(bundle: Bundle = .main, session: any UpdateSession = URLSession.shared) -> UpdateChecker {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        return UpdateChecker(
            manifestURL: publicManifestURL,
            currentVersion: version,
            currentMacOSVersion: "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)",
            session: session
        )
    }

    func check(manual: Bool) async -> UpdateResult {
        do {
            let request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed(.invalidResponse)
            }
            guard let finalURL = httpResponse.url,
                  Self.isAllowedFinalResponseURL(finalURL, requestedURL: manifestURL),
                  data.count <= Self.maximumResponseBytes else {
                return .failed(.invalidResponse)
            }
            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let declaredBytes = Int(contentLength),
               declaredBytes > Self.maximumResponseBytes {
                return .failed(.invalidResponse)
            }
            guard httpResponse.statusCode == 200 else {
                if Self.isTransient(statusCode: httpResponse.statusCode) {
                    return .failed(manual ? .actionableNetwork : .silentTransient)
                }
                return .failed(.invalidResponse)
            }
            return evaluate(try decodeManifest(from: data))
        } catch let failure as UpdateCheckFailure {
            return .failed(failure)
        } catch let error as URLError {
            if Self.isTransient(error) && !manual {
                return .failed(.silentTransient)
            }
            return .failed(.actionableNetwork)
        } catch {
            return .failed(.invalidManifest)
        }
    }

    private func decodeManifest(from data: Data) throws -> MacOSUpdateManifest {
        let envelope: ContentsEnvelope
        do {
            envelope = try JSONDecoder().decode(ContentsEnvelope.self, from: data)
        } catch {
            throw UpdateCheckFailure.invalidManifest
        }
        guard envelope.encoding == "base64" else {
            throw UpdateCheckFailure.invalidManifest
        }
        let compactBase64 = envelope.content
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let decoded = Data(base64Encoded: compactBase64) else {
            throw UpdateCheckFailure.invalidManifest
        }
        guard decoded.count <= Self.maximumDecodedManifestBytes else {
            throw UpdateCheckFailure.invalidManifest
        }
        do {
            return try JSONDecoder().decode(MacOSUpdateManifest.self, from: decoded)
        } catch {
            throw UpdateCheckFailure.invalidManifest
        }
    }

    private func evaluate(_ manifest: MacOSUpdateManifest) -> UpdateResult {
        guard manifest.schemaVersion == 1,
              !manifest.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ISO8601DateFormatter().date(from: manifest.publishedAt) != nil else {
            return .failed(.invalidManifest)
        }
        guard manifest.platform == "macos" else {
            return .failed(.wrongPlatformManifest)
        }
        guard let latest = SemanticVersion(manifest.latestVersion),
              let current = SemanticVersion(currentVersion) else {
            return .failed(.invalidVersion)
        }
        guard let minimumMacOS = SemanticVersion(manifest.minimumMacOS),
              let runningMacOS = SemanticVersion(currentMacOSVersion) else {
            return .failed(.invalidMinimumMacOS)
        }
        guard Self.isSecureHTTPSURL(manifest.releaseURL),
              Self.isSecureHTTPSURL(manifest.downloadURL) else {
            return .failed(.insecureURL)
        }
        guard manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({
                  $0.isASCII && (($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f"))
              }) else {
            return .failed(.invalidChecksum)
        }
        guard latest > current else { return .upToDate }
        guard runningMacOS >= minimumMacOS else { return .unsupportedOS(manifest) }
        return .available(manifest)
    }

    private static func isSecureHTTPSURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
    }

    private static func isAllowedFinalResponseURL(_ finalURL: URL, requestedURL: URL) -> Bool {
        guard isSecureHTTPSURL(requestedURL), isSecureHTTPSURL(finalURL),
              let requested = URLComponents(url: requestedURL, resolvingAgainstBaseURL: false),
              let final = URLComponents(url: finalURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        return requested.host?.lowercased() == final.host?.lowercased()
            && effectiveHTTPSPort(requested.port) == effectiveHTTPSPort(final.port)
            && requested.path == final.path
    }

    private static func effectiveHTTPSPort(_ port: Int?) -> Int {
        port ?? 443
    }

    private static func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}
