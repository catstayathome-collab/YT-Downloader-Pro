import Foundation

enum AuthenticationProviderError: Error, Equatable, Sendable {
    case cancelled
    case invalidSession
    case expiredSession
}

protocol AuthenticationProvider: Sendable {
    var kind: AuthenticationProviderKind { get }
    func signIn() async throws -> AuthenticationSession
    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession
    func signOut(refreshCredential: String?) async
}

struct AuthenticationProviderRegistry: Sendable {
    private let providers: [AuthenticationProviderKind: any AuthenticationProvider]

    init(_ providers: [any AuthenticationProvider]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind, $0) })
    }

    func provider(for kind: AuthenticationProviderKind) -> (any AuthenticationProvider)? {
        providers[kind]
    }

    static func mock() -> AuthenticationProviderRegistry {
        AuthenticationProviderRegistry(AuthenticationProviderKind.allCases.map { MockAuthenticationProvider(kind: $0) })
    }
}
