import Foundation
@testable import YTDownloaderPro2

enum VaultOperation: Equatable, Sendable {
    case load(AuthEnvironment)
    case save(AuthEnvironment)
    case delete(AuthEnvironment)
}

actor RecordingCredentialVault: CredentialVault {
    private(set) var operations: [VaultOperation] = []
    private(set) var savedEnvelope: StoredCredentialEnvelope?
    private var storedEnvelope: StoredCredentialEnvelope?
    private let loadError: CredentialVaultError?
    private let saveError: CredentialVaultError?
    private let deleteError: CredentialVaultError?

    init(
        initial: StoredCredentialEnvelope? = nil,
        loadError: CredentialVaultError? = nil,
        saveError: CredentialVaultError? = nil,
        deleteError: CredentialVaultError? = nil
    ) {
        storedEnvelope = initial
        self.loadError = loadError
        self.saveError = saveError
        self.deleteError = deleteError
    }

    func load(environment: AuthEnvironment) async throws -> StoredCredentialEnvelope? {
        operations.append(.load(environment))
        if let loadError { throw loadError }
        return storedEnvelope
    }

    func save(_ envelope: StoredCredentialEnvelope, environment: AuthEnvironment) async throws {
        operations.append(.save(environment))
        if let saveError { throw saveError }
        storedEnvelope = envelope
        savedEnvelope = envelope
    }

    func delete(environment: AuthEnvironment) async throws {
        operations.append(.delete(environment))
        if let deleteError { throw deleteError }
        storedEnvelope = nil
    }
}

actor AuthenticationCallCounter {
    private(set) var signOutCount = 0

    func recordSignOut() {
        signOutCount += 1
    }
}

struct ImmediateAuthenticationProvider: AuthenticationProvider {
    let kind: AuthenticationProviderKind
    let signInResult: Result<AuthenticationSession, AuthenticationProviderError>
    let restoreResult: Result<AuthenticationSession, AuthenticationProviderError>
    let counter: AuthenticationCallCounter

    init(
        kind: AuthenticationProviderKind,
        signInResult: Result<AuthenticationSession, AuthenticationProviderError> = .failure(.cancelled),
        restoreResult: Result<AuthenticationSession, AuthenticationProviderError> = .failure(.invalidSession),
        counter: AuthenticationCallCounter = AuthenticationCallCounter()
    ) {
        self.kind = kind
        self.signInResult = signInResult
        self.restoreResult = restoreResult
        self.counter = counter
    }

    func signIn() async throws -> AuthenticationSession {
        try signInResult.get()
    }

    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession {
        try restoreResult.get()
    }

    func signOut(refreshCredential: String?) async {
        await counter.recordSignOut()
    }
}

extension AccountSummary {
    static func fixture(provider: AuthenticationProviderKind) -> AccountSummary {
        AccountSummary(
            provider: provider,
            accountID: "mock-account",
            displayName: "Demo User",
            planPreview: .pro,
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }
}

extension AuthenticationSession {
    static func fixture(
        provider: AuthenticationProviderKind,
        accessToken: String = "memory-access"
    ) -> AuthenticationSession {
        AuthenticationSession(
            summary: .fixture(provider: provider),
            accessToken: accessToken,
            refreshCredential: "mock-refresh"
        )
    }
}
