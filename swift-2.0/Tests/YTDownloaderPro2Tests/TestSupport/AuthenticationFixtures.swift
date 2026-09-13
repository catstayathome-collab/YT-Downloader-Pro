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
    private(set) var operations: [AuthenticationProviderOperation] = []
    private(set) var signOutCount = 0
    private(set) var signOutCredentials: [String?] = []

    func recordSignIn() {
        operations.append(.signIn)
    }

    func recordRestore(from envelope: StoredCredentialEnvelope) {
        operations.append(.restore(envelope))
    }

    func recordSignOut(refreshCredential: String?) {
        operations.append(.signOut(refreshCredential))
        signOutCount += 1
        signOutCredentials.append(refreshCredential)
    }
}

enum AuthenticationProviderOperation: Equatable, Sendable {
    case signIn
    case restore(StoredCredentialEnvelope)
    case signOut(String?)
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
        await counter.recordSignIn()
        return try signInResult.get()
    }

    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession {
        await counter.recordRestore(from: envelope)
        return try restoreResult.get()
    }

    func signOut(refreshCredential: String?) async {
        await counter.recordSignOut(refreshCredential: refreshCredential)
    }
}

actor ControlledAuthenticationProvider: AuthenticationProvider {
    nonisolated let kind: AuthenticationProviderKind
    private(set) var signInCallCount = 0
    private var signInContinuation: CheckedContinuation<AuthenticationSession, Error>?

    init(kind: AuthenticationProviderKind) {
        self.kind = kind
    }

    func signIn() async throws -> AuthenticationSession {
        signInCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            signInContinuation = continuation
        }
    }

    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession {
        throw AuthenticationProviderError.invalidSession
    }

    func signOut(refreshCredential: String?) async {}

    func waitUntilSignInStarts() async {
        while signInCallCount == 0 {
            await Task.yield()
        }
    }

    func finishSignIn(_ result: Result<AuthenticationSession, AuthenticationProviderError>) {
        let continuation = signInContinuation
        signInContinuation = nil
        switch result {
        case let .success(session):
            continuation?.resume(returning: session)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }
}

actor ControlledCredentialVault: CredentialVault {
    private(set) var operations: [VaultOperation] = []
    private(set) var storedEnvelope: StoredCredentialEnvelope?
    private var suspendsNextSave: Bool
    private var suspendsNextDelete: Bool
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var deleteContinuation: CheckedContinuation<Void, Never>?

    init(
        initial: StoredCredentialEnvelope? = nil,
        suspendNextSave: Bool = false,
        suspendNextDelete: Bool = false
    ) {
        storedEnvelope = initial
        suspendsNextSave = suspendNextSave
        suspendsNextDelete = suspendNextDelete
    }

    func load(environment: AuthEnvironment) async throws -> StoredCredentialEnvelope? {
        operations.append(.load(environment))
        return storedEnvelope
    }

    func save(_ envelope: StoredCredentialEnvelope, environment: AuthEnvironment) async throws {
        operations.append(.save(environment))
        if suspendsNextSave {
            suspendsNextSave = false
            await withCheckedContinuation { continuation in
                saveContinuation = continuation
            }
        }
        storedEnvelope = envelope
    }

    func delete(environment: AuthEnvironment) async throws {
        operations.append(.delete(environment))
        if suspendsNextDelete {
            suspendsNextDelete = false
            await withCheckedContinuation { continuation in
                deleteContinuation = continuation
            }
        }
        storedEnvelope = nil
    }

    func waitUntilSaveStarts(count: Int = 1, maximumYields: Int = 10_000) async -> Bool {
        for _ in 0..<maximumYields {
            let saveCount = operations.filter({ operation in
                if case .save = operation { return true }
                return false
            }).count
            if saveCount >= count { return true }
            await Task.yield()
        }
        return operations.filter({ operation in
            if case .save = operation { return true }
            return false
        }).count >= count
    }

    func waitUntilDeleteStarts() async {
        while !operations.contains(where: { operation in
            if case .delete = operation { return true }
            return false
        }) {
            await Task.yield()
        }
    }

    func finishSuspendedSave() {
        let continuation = saveContinuation
        saveContinuation = nil
        continuation?.resume()
    }

    func finishSuspendedDelete() {
        let continuation = deleteContinuation
        deleteContinuation = nil
        continuation?.resume()
    }
}

actor RecordingAuthenticationDiagnostics: AuthenticationDiagnosticsRecording {
    private(set) var events: [AuthenticationDiagnosticEvent] = []

    func record(_ event: AuthenticationDiagnosticEvent) async {
        events.append(event)
    }

    func waitForEventCount(_ count: Int) async {
        while events.count < count {
            await Task.yield()
        }
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
        accountID: String = "mock-account",
        displayName: String = "Demo User",
        expiresAt: Date = Date(timeIntervalSince1970: 4_000_000_000),
        accessToken: String = "memory-access",
        refreshCredential: String = "mock-refresh"
    ) -> AuthenticationSession {
        AuthenticationSession(
            summary: AccountSummary(
                provider: provider,
                accountID: accountID,
                displayName: displayName,
                planPreview: .pro,
                expiresAt: expiresAt
            ),
            accessToken: accessToken,
            refreshCredential: refreshCredential
        )
    }
}

extension AccountSessionStore {
    static func fixture(
        provider: any AuthenticationProvider,
        vault: any CredentialVault = RecordingCredentialVault(),
        diagnostics: any AuthenticationDiagnosticsRecording = RecordingAuthenticationDiagnostics()
    ) -> AccountSessionStore {
        AccountSessionStore(
            environment: .mock,
            vault: vault,
            providers: .init([provider]),
            now: { Date(timeIntervalSince1970: 1_000) },
            diagnostics: diagnostics
        )
    }
}
