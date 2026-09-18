import Foundation
@testable import YTDownloaderPro2

enum VaultOperation: Equatable, Sendable {
    case load(AuthEnvironment)
    case save(AuthEnvironment)
    case delete(AuthEnvironment)
}

actor AuthenticationCompletionProbe {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

actor RecordingCredentialVault: CredentialVault {
    private(set) var operations: [VaultOperation] = []
    private(set) var savedEnvelope: StoredCredentialEnvelope?
    private var storedEnvelope: StoredCredentialEnvelope?
    private let loadError: CredentialVaultError?
    private let saveError: CredentialVaultError?
    private let deleteError: CredentialVaultError?
    private var remainingDeleteErrors: [CredentialVaultError?]

    init(
        initial: StoredCredentialEnvelope? = nil,
        loadError: CredentialVaultError? = nil,
        saveError: CredentialVaultError? = nil,
        deleteError: CredentialVaultError? = nil,
        deleteErrors: [CredentialVaultError?] = []
    ) {
        storedEnvelope = initial
        self.loadError = loadError
        self.saveError = saveError
        self.deleteError = deleteError
        remainingDeleteErrors = deleteErrors
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
        if !remainingDeleteErrors.isEmpty {
            if let error = remainingDeleteErrors.removeFirst() { throw error }
        }
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
    private var signInStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var signInFinishWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasFinishedSignIn = false

    init(kind: AuthenticationProviderKind) {
        self.kind = kind
    }

    func signIn() async throws -> AuthenticationSession {
        signInCallCount += 1
        defer {
            hasFinishedSignIn = true
            let waiters = signInFinishWaiters
            signInFinishWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        return try await withCheckedThrowingContinuation { continuation in
            signInContinuation = continuation
            let waiters = signInStartWaiters
            signInStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession {
        throw AuthenticationProviderError.invalidSession
    }

    func signOut(refreshCredential: String?) async {}

    func waitUntilSignInStarts() async {
        guard signInCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            signInStartWaiters.append(continuation)
        }
    }

    func waitUntilSignInFinishes() async {
        guard !hasFinishedSignIn else { return }
        await withCheckedContinuation { continuation in
            signInFinishWaiters.append(continuation)
        }
    }

    var hasPendingSignIn: Bool {
        signInContinuation != nil
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
    private var suspendsNextSaveAfterWrite: Bool
    private var suspendedDeleteCounts: Set<Int>
    private let deleteError: CredentialVaultError?
    private var remainingDeleteErrors: [CredentialVaultError?]
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var deleteContinuation: CheckedContinuation<Void, Never>?
    private var saveWriteCount = 0
    private var deleteStartCount = 0
    private var saveWriteWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var deleteStartWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        initial: StoredCredentialEnvelope? = nil,
        suspendNextSaveAfterWrite: Bool = false,
        suspendNextDelete: Bool = false,
        deleteError: CredentialVaultError? = nil,
        suspendDeleteCounts: Set<Int> = [],
        deleteErrors: [CredentialVaultError?] = []
    ) {
        storedEnvelope = initial
        suspendsNextSaveAfterWrite = suspendNextSaveAfterWrite
        suspendedDeleteCounts = suspendDeleteCounts
        if suspendNextDelete { suspendedDeleteCounts.insert(1) }
        self.deleteError = deleteError
        remainingDeleteErrors = deleteErrors
    }

    func load(environment: AuthEnvironment) async throws -> StoredCredentialEnvelope? {
        operations.append(.load(environment))
        return storedEnvelope
    }

    func save(_ envelope: StoredCredentialEnvelope, environment: AuthEnvironment) async throws {
        operations.append(.save(environment))
        storedEnvelope = envelope
        saveWriteCount += 1
        resumeSatisfiedWaiters(&saveWriteWaiters, count: saveWriteCount)
        if suspendsNextSaveAfterWrite {
            suspendsNextSaveAfterWrite = false
            await suspendSave()
        }
    }

    func delete(environment: AuthEnvironment) async throws {
        operations.append(.delete(environment))
        deleteStartCount += 1
        resumeSatisfiedWaiters(&deleteStartWaiters, count: deleteStartCount)
        if suspendedDeleteCounts.remove(deleteStartCount) != nil {
            await withCheckedContinuation { continuation in
                deleteContinuation = continuation
            }
        }
        if !remainingDeleteErrors.isEmpty {
            if let error = remainingDeleteErrors.removeFirst() { throw error }
        }
        if let deleteError { throw deleteError }
        storedEnvelope = nil
    }

    func waitUntilSaveWrites(count: Int = 1) async {
        guard saveWriteCount < count else { return }
        await withCheckedContinuation { continuation in
            saveWriteWaiters.append((count, continuation))
        }
    }

    func waitUntilDeleteStarts(count: Int = 1) async {
        guard deleteStartCount < count else { return }
        await withCheckedContinuation { continuation in
            deleteStartWaiters.append((count, continuation))
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

    private func suspendSave() async {
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
    }

    private func resumeSatisfiedWaiters(
        _ waiters: inout [(count: Int, continuation: CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        let satisfied = waiters.filter { $0.count <= count }
        waiters.removeAll { $0.count <= count }
        satisfied.forEach { $0.continuation.resume() }
    }
}

actor RecordingAuthenticationDiagnostics: AuthenticationDiagnosticsRecording {
    private(set) var events: [AuthenticationDiagnosticEvent] = []
    private var eventWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ event: AuthenticationDiagnosticEvent) async {
        events.append(event)
        let satisfied = eventWaiters.filter { $0.count <= events.count }
        eventWaiters.removeAll { $0.count <= events.count }
        satisfied.forEach { $0.continuation.resume() }
    }

    func waitForEventCount(_ count: Int) async {
        guard events.count < count else { return }
        await withCheckedContinuation { continuation in
            eventWaiters.append((count, continuation))
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
