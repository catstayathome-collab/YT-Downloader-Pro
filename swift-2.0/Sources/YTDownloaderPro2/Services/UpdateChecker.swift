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

protocol UpdateResponseBody: Sendable {
    func nextChunk() async throws -> Data?
    func cancel()
}

struct UpdateSessionResponse: @unchecked Sendable {
    let response: HTTPURLResponse
    let body: any UpdateResponseBody
}

protocol UpdateSession: Sendable {
    func response(for request: URLRequest, maximumBytes: Int) async throws -> UpdateSessionResponse
}

enum UpdateTransportError: Error {
    case invalidResponse
    case responseTooLarge
}

/// A macOS 13-compatible streaming transport that cancels before retaining more than the byte limit.
struct URLSessionUpdateSession: UpdateSession, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func response(for request: URLRequest, maximumBytes: Int) async throws -> UpdateSessionResponse {
        let transfer = URLSessionUpdateTransfer(configuration: configuration, maximumBytes: maximumBytes)
        return try await transfer.start(request)
    }
}

private final class URLSessionUpdateTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private var receivedBytes = 0
    private var responseContinuation: CheckedContinuation<UpdateSessionResponse, Error>?
    private var responseResolved = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var requestedURL: URL?
    private lazy var body = StreamingUpdateResponseBody { [weak self] in
        self?.cancel()
    }

    init(configuration: URLSessionConfiguration, maximumBytes: Int) {
        self.configuration = configuration
        self.maximumBytes = maximumBytes
    }

    func start(_ request: URLRequest) async throws -> UpdateSessionResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let shouldStart = lock.withLock { () -> Bool in
                    guard !responseResolved else { return false }
                    self.responseContinuation = continuation
                    self.session = session
                    self.task = task
                    self.requestedURL = request.url
                    return true
                }
                guard shouldStart else {
                    continuation.resume(throwing: CancellationError())
                    session.invalidateAndCancel()
                    return
                }
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let state = lock.withLock { () -> (URLSessionDataTask?, URLSession?, CheckedContinuation<UpdateSessionResponse, Error>?) in
            let continuation = responseResolved ? nil : responseContinuation
            responseContinuation = nil
            responseResolved = true
            return (task, session, continuation)
        }
        state.2?.resume(throwing: CancellationError())
        state.0?.cancel()
        state.1?.invalidateAndCancel()
        body.finish(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            resolveResponse(throwing: UpdateTransportError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        let originalURL = lock.withLock { requestedURL }
        guard let originalURL,
              let finalURL = httpResponse.url,
              UpdateChecker.isAllowedFinalResponseURL(finalURL, requestedURL: originalURL) else {
            resolveResponse(throwing: UpdateTransportError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        if httpResponse.expectedContentLength > Int64(maximumBytes) {
            resolveResponse(throwing: UpdateTransportError.responseTooLarge)
            completionHandler(.cancel)
            return
        }

        resolveResponse(with: UpdateSessionResponse(response: httpResponse, body: body))
        guard httpResponse.statusCode == 200 else {
            body.finish()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceedsLimit = lock.withLock { () -> Bool in
            guard data.count <= maximumBytes - receivedBytes else { return true }
            receivedBytes += data.count
            return false
        }
        guard !exceedsLimit else {
            body.finish(throwing: UpdateTransportError.responseTooLarge)
            dataTask.cancel()
            session.invalidateAndCancel()
            return
        }
        body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resolveResponse(throwing: error)
            body.finish(throwing: error)
        } else {
            body.finish()
        }
        session.finishTasksAndInvalidate()
    }

    private func resolveResponse(with response: UpdateSessionResponse) {
        let continuation = lock.withLock { () -> CheckedContinuation<UpdateSessionResponse, Error>? in
            guard !responseResolved else { return nil }
            responseResolved = true
            defer { responseContinuation = nil }
            return responseContinuation
        }
        continuation?.resume(returning: response)
    }

    private func resolveResponse(throwing error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<UpdateSessionResponse, Error>? in
            guard !responseResolved else { return nil }
            responseResolved = true
            defer { responseContinuation = nil }
            return responseContinuation
        }
        continuation?.resume(throwing: error)
    }
}

private final class StreamingUpdateResponseBody: UpdateResponseBody, @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationHandler: @Sendable () -> Void
    private var chunks: [Data] = []
    private var continuation: CheckedContinuation<Data?, Error>?
    private var completion: Result<Void, Error>?

    init(cancellationHandler: @escaping @Sendable () -> Void) {
        self.cancellationHandler = cancellationHandler
    }

    func nextChunk() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action = lock.withLock { () -> BodyAction in
                    if !chunks.isEmpty {
                        return .chunk(chunks.removeFirst())
                    }
                    if let completion {
                        switch completion {
                        case .success:
                            return .finished
                        case let .failure(error):
                            return .failure(error)
                        }
                    }
                    self.continuation = continuation
                    return .wait
                }
                action.resume(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        cancellationHandler()
    }

    func yield(_ data: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
            guard completion == nil else { return nil }
            guard let continuation else {
                chunks.append(data)
                return nil
            }
            self.continuation = nil
            return continuation
        }
        waiter?.resume(returning: data)
    }

    func finish(throwing error: Error? = nil) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
            guard completion == nil else { return nil }
            completion = error.map(Result.failure) ?? .success(())
            defer { continuation = nil }
            return continuation
        }
        if let error {
            waiter?.resume(throwing: error)
        } else {
            waiter?.resume(returning: nil)
        }
    }

    private enum BodyAction {
        case wait
        case chunk(Data)
        case finished
        case failure(Error)

        func resume(_ continuation: CheckedContinuation<Data?, Error>) {
            switch self {
            case .wait:
                break
            case let .chunk(data):
                continuation.resume(returning: data)
            case .finished:
                continuation.resume(returning: nil)
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        }
    }
}

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

    static func live(bundle: Bundle = .main, session: any UpdateSession = URLSessionUpdateSession()) -> UpdateChecker {
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
            let streamedResponse = try await session.response(
                for: request,
                maximumBytes: Self.maximumResponseBytes
            )
            let httpResponse = streamedResponse.response
            guard let finalURL = httpResponse.url,
                  Self.isAllowedFinalResponseURL(finalURL, requestedURL: manifestURL) else {
                streamedResponse.body.cancel()
                return .failed(.invalidResponse)
            }
            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") {
                guard let declaredBytes = Int(contentLength),
                      declaredBytes >= 0,
                      declaredBytes <= Self.maximumResponseBytes else {
                    streamedResponse.body.cancel()
                    return .failed(.invalidResponse)
                }
            }
            guard httpResponse.statusCode == 200 else {
                streamedResponse.body.cancel()
                if Self.isTransient(statusCode: httpResponse.statusCode) {
                    return .failed(manual ? .actionableNetwork : .silentTransient)
                }
                return .failed(.invalidResponse)
            }
            let data = try await Self.collect(
                streamedResponse.body,
                maximumBytes: Self.maximumResponseBytes
            )
            return evaluate(try decodeManifest(from: data))
        } catch UpdateTransportError.invalidResponse, UpdateTransportError.responseTooLarge {
            return .failed(.invalidResponse)
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

    private static func collect(_ body: any UpdateResponseBody, maximumBytes: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            var data = Data()
            while let chunk = try await body.nextChunk() {
                guard chunk.count <= maximumBytes - data.count else {
                    body.cancel()
                    throw UpdateTransportError.responseTooLarge
                }
                data.append(chunk)
            }
            return data
        } onCancel: {
            body.cancel()
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

    fileprivate static func isAllowedFinalResponseURL(_ finalURL: URL, requestedURL: URL) -> Bool {
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
