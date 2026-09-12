import Foundation

struct MockAuthenticationProvider: AuthenticationProvider {
    let kind: AuthenticationProviderKind
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    init(
        kind: AuthenticationProviderKind,
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.kind = kind
        self.now = now
        self.makeUUID = makeUUID
    }

    func signIn() async throws -> AuthenticationSession {
        try Task.checkCancellation()
        let identifier = makeUUID().uuidString.lowercased()
        let summary = AccountSummary(
            provider: kind,
            accountID: "mock-\(kind.rawValue)-\(identifier)",
            displayName: kind == .google ? "Demo Google User" : "Demo Apple User",
            planPreview: .pro,
            expiresAt: now().addingTimeInterval(30 * 24 * 60 * 60)
        )
        return AuthenticationSession(
            summary: summary,
            accessToken: "mock-access-\(identifier)",
            refreshCredential: "mock-refresh-\(identifier)"
        )
    }

    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession {
        try Task.checkCancellation()
        guard envelope.summary.provider == kind,
              !envelope.summary.accountID.isEmpty,
              !envelope.summary.displayName.isEmpty,
              !envelope.refreshCredential.isEmpty else {
            throw AuthenticationProviderError.invalidSession
        }
        guard envelope.summary.expiresAt > now() else {
            throw AuthenticationProviderError.expiredSession
        }
        return AuthenticationSession(
            summary: envelope.summary,
            accessToken: "mock-access-\(makeUUID().uuidString.lowercased())",
            refreshCredential: envelope.refreshCredential
        )
    }

    func signOut(refreshCredential: String?) async {
        // Phase 1 has no provider or network state to revoke.
    }
}
