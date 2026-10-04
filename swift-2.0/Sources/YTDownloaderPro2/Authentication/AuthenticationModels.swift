import Foundation

enum AuthEnvironment: String, Equatable, Hashable, Sendable {
    case disabled
    case mock
    case staging
    case production

    static func resolve(from environment: [String: String] = ProcessInfo.processInfo.environment) -> AuthEnvironment {
        environment["YTDP_AUTH_MODE"] == "mock" ? .mock : .disabled
    }

    var storageNamespace: String { rawValue }

    var supportsAuthentication: Bool {
        self == .mock || self == .staging
    }
}

enum AuthenticationProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case google
    case apple
}

struct AccountSummary: Codable, Equatable, Sendable {
    let provider: AuthenticationProviderKind
    let accountID: String
    let displayName: String
    let maskedEmail: String?
    let expiresAt: Date
}

struct AuthenticatedSessionContext: Equatable, Sendable {
    let accountID: String
    let accessToken: String
    let expiresAt: Date
}

struct StoredCredentialEnvelope: Codable, Equatable, Sendable {
    let summary: AccountSummary
    let refreshCredential: String
}

struct AuthenticationSession: Equatable, Sendable {
    let summary: AccountSummary
    let accessToken: String
    let refreshCredential: String

    var storedEnvelope: StoredCredentialEnvelope {
        StoredCredentialEnvelope(summary: summary, refreshCredential: refreshCredential)
    }
}

enum AuthPresentationError: String, Equatable, Sendable {
    case providerUnavailable
    case invalidSession
    case expiredSession
    case credentialStorageUnavailable
    case credentialRemovalFailed
    case signInFailed
}

enum AccountSessionState: Equatable, Sendable {
    case disabled
    case signedOut
    case signingIn(AuthenticationProviderKind)
    case restoring
    case signedIn(AccountSummary)
    case requiresReauthentication(AuthenticationProviderKind?)
    case failed(AuthPresentationError)
    case signingOut
}
