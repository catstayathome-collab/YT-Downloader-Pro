import Combine
import Foundation

@MainActor
final class AccountSessionStore: ObservableObject {
    @Published private(set) var state: AccountSessionState
    @Published private(set) var isAuthenticationCancellationAvailable = false
    let environment: AuthEnvironment

    private let vault: any CredentialVault
    private let providers: AuthenticationProviderRegistry
    private let now: @Sendable () -> Date
    private let diagnostics: any AuthenticationDiagnosticsRecording
    private var accessToken: String?
    private var refreshCredential: String?
    private var currentSummary: AccountSummary?
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?
    private var activePriorState: AccountSessionState?
    private var activeProviderOperation: CancellableAuthenticationProviderOperation?
    private var diagnosticsTask: Task<Void, Never>?

    init(
        environment: AuthEnvironment,
        vault: any CredentialVault,
        providers: AuthenticationProviderRegistry,
        now: @escaping @Sendable () -> Date = { Date() },
        diagnostics: any AuthenticationDiagnosticsRecording = SystemAuthenticationDiagnosticsRecorder()
    ) {
        self.environment = environment
        self.vault = vault
        self.providers = providers
        self.now = now
        self.diagnostics = diagnostics
        self.state = environment == .disabled ? .disabled : .signedOut
    }

    static func live(environment: AuthEnvironment = .resolve()) -> AccountSessionStore {
        AccountSessionStore(
            environment: environment,
            vault: KeychainCredentialVault(),
            providers: environment == .mock ? .mock() : .init([])
        )
    }

    func signIn(with kind: AuthenticationProviderKind) async {
        guard environment == .mock else { return }
        guard let (operationID, priorState) = beginOperation() else { return }
        state = .signingIn(kind)
        isAuthenticationCancellationAvailable = true
        recordDiagnostic(.signInStarted)
        guard let provider = providers.provider(for: kind) else {
            finishOperation(operationID, state: .failed(.providerUnavailable))
            recordDiagnostic(.signInFailed)
            return
        }
        let providerOperation = CancellableAuthenticationProviderOperation {
            try await provider.signIn()
        }
        activeProviderOperation = providerOperation

        do {
            let session = try await providerOperation.value()
            guard owns(operationID) else { return }
            try validate(session, provider: kind)
            guard beginCredentialCommit(operationID) else { return }
            try await saveCredential(session.storedEnvelope)
            guard owns(operationID) else { return }
            accessToken = session.accessToken
            refreshCredential = session.refreshCredential
            currentSummary = session.summary
            finishOperation(operationID, state: .signedIn(session.summary))
        } catch {
            finishSignIn(operationID, priorState: priorState, with: error)
        }
    }

    func restoreSession() async {
        guard environment == .mock else {
            state = .disabled
            return
        }
        guard let (operationID, priorState) = beginOperation() else { return }
        state = .restoring
        isAuthenticationCancellationAvailable = true
        var restoringProvider: AuthenticationProviderKind?

        do {
            let storedEnvelope = try await vault.load(environment: environment)
            guard owns(operationID) else { return }
            guard let envelope = storedEnvelope else {
                finishOperation(operationID, state: .signedOut)
                return
            }
            restoringProvider = envelope.summary.provider
            guard let provider = providers.provider(for: envelope.summary.provider) else {
                finishOperation(operationID, state: .requiresReauthentication(nil))
                return
            }
            let providerOperation = CancellableAuthenticationProviderOperation {
                try await provider.restore(from: envelope)
            }
            activeProviderOperation = providerOperation
            let session = try await providerOperation.value()
            guard owns(operationID) else { return }
            try validate(session, provider: envelope.summary.provider)
            accessToken = session.accessToken
            refreshCredential = session.refreshCredential
            currentSummary = session.summary
            finishOperation(operationID, state: .signedIn(session.summary))
            recordDiagnostic(.sessionRestored)
        } catch {
            await finishRestoration(
                operationID,
                priorState: priorState,
                provider: restoringProvider,
                with: error
            )
        }
    }

    func cancelAuthentication() {
        let cancellation: (isCancellable: Bool, event: AuthenticationDiagnosticEvent?) = switch state {
        case .signingIn:
            (true, AuthenticationDiagnosticEvent.signInCancelled)
        case .restoring:
            (true, nil)
        default:
            (false, nil)
        }
        guard cancellation.isCancellable,
              isAuthenticationCancellationAvailable,
              activeOperationID != nil else { return }
        let priorState = activePriorState ?? (environment == .disabled ? .disabled : .signedOut)
        activeProviderOperation?.cancel()
        nextOperationID &+= 1
        activeOperationID = nil
        activePriorState = nil
        activeProviderOperation = nil
        isAuthenticationCancellationAvailable = false
        state = priorState
        if let cancellationEvent = cancellation.event { recordDiagnostic(cancellationEvent) }
    }

    func signOut() async {
        guard environment == .mock,
              activeOperationID == nil,
              let summary = currentSummary else { return }
        guard let (operationID, _) = beginOperation() else { return }
        state = .signingOut
        let credential = refreshCredential
        accessToken = nil
        await providers.provider(for: summary.provider)?.signOut(refreshCredential: credential)
        guard owns(operationID) else { return }
        guard beginCredentialCommit(operationID) else { return }
        do {
            try await deleteCredential()
            guard owns(operationID) else { return }
            refreshCredential = nil
            currentSummary = nil
            finishOperation(operationID, state: .signedOut)
            recordDiagnostic(.signOutCompleted)
        } catch {
            guard owns(operationID) else { return }
            finishOperation(operationID, state: .failed(.credentialRemovalFailed))
            recordDiagnostic(.storageUnavailable)
        }
    }

    private func beginOperation() -> (UInt64, AccountSessionState)? {
        guard activeOperationID == nil else { return nil }
        nextOperationID &+= 1
        activeOperationID = nextOperationID
        activePriorState = state
        return (nextOperationID, state)
    }

    private func owns(_ id: UInt64) -> Bool {
        activeOperationID == id
    }

    private func finishOperation(_ id: UInt64, state newState: AccountSessionState) {
        guard owns(id) else { return }
        activeOperationID = nil
        activePriorState = nil
        activeProviderOperation = nil
        isAuthenticationCancellationAvailable = false
        state = newState
    }

    private func beginCredentialCommit(_ operationID: UInt64) -> Bool {
        guard owns(operationID) else { return false }
        activeProviderOperation = nil
        isAuthenticationCancellationAvailable = false
        return true
    }

    private func finishSignIn(
        _ operationID: UInt64,
        priorState: AccountSessionState,
        with error: Error
    ) {
        guard owns(operationID) else { return }
        switch error {
        case is CancellationError, AuthenticationProviderError.cancelled:
            finishOperation(operationID, state: priorState)
            recordDiagnostic(.signInCancelled)
        case AuthenticationProviderError.expiredSession:
            finishOperation(operationID, state: .failed(.expiredSession))
            recordDiagnostic(.sessionExpired)
        case is CredentialVaultError:
            finishOperation(operationID, state: .failed(.credentialStorageUnavailable))
            recordDiagnostic(.storageUnavailable)
        default:
            finishOperation(operationID, state: .failed(presentationError(for: error)))
            recordDiagnostic(.signInFailed)
        }
    }

    private func finishRestoration(
        _ operationID: UInt64,
        priorState: AccountSessionState,
        provider: AuthenticationProviderKind?,
        with error: Error
    ) async {
        guard owns(operationID) else { return }
        switch error {
        case is CancellationError, AuthenticationProviderError.cancelled:
            finishOperation(operationID, state: priorState)
        case AuthenticationProviderError.expiredSession:
            finishOperation(operationID, state: .requiresReauthentication(provider))
            recordDiagnostic(.sessionExpired)
        case AuthenticationProviderError.invalidSession, CredentialVaultError.malformedRecord:
            await removeInvalidCredential(operationID)
        default:
            finishOperation(operationID, state: .failed(.credentialStorageUnavailable))
            recordDiagnostic(.storageUnavailable)
        }
    }

    private func removeInvalidCredential(_ operationID: UInt64) async {
        guard beginCredentialCommit(operationID) else { return }
        do {
            try await deleteCredential()
            guard owns(operationID) else { return }
            finishOperation(operationID, state: .requiresReauthentication(nil))
        } catch {
            guard owns(operationID) else { return }
            finishOperation(operationID, state: .failed(.credentialRemovalFailed))
            recordDiagnostic(.storageUnavailable)
        }
    }

    private func recordDiagnostic(_ event: AuthenticationDiagnosticEvent) {
        let precedingTask = diagnosticsTask
        let diagnostics = diagnostics
        diagnosticsTask = Task {
            if let precedingTask { await precedingTask.value }
            await diagnostics.record(event)
        }
    }

    private func saveCredential(_ envelope: StoredCredentialEnvelope) async throws {
        let vault = vault
        let environment = environment
        try await Task.detached {
            try await vault.save(envelope, environment: environment)
        }.value
    }

    private func deleteCredential() async throws {
        let vault = vault
        let environment = environment
        try await Task.detached {
            try await vault.delete(environment: environment)
        }.value
    }

    private func validate(
        _ session: AuthenticationSession,
        provider: AuthenticationProviderKind
    ) throws {
        guard session.summary.provider == provider,
              hasOpaqueContent(session.summary.accountID),
              hasOpaqueContent(session.summary.displayName),
              hasOpaqueContent(session.accessToken),
              hasOpaqueContent(session.refreshCredential) else {
            throw AuthenticationProviderError.invalidSession
        }
        guard session.summary.expiresAt > now() else {
            throw AuthenticationProviderError.expiredSession
        }
    }

    private func hasOpaqueContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func presentationError(for error: Error) -> AuthPresentationError {
        switch error {
        case AuthenticationProviderError.invalidSession:
            .invalidSession
        case AuthenticationProviderError.expiredSession:
            .expiredSession
        case is CredentialVaultError:
            .credentialStorageUnavailable
        default:
            .signInFailed
        }
    }
}

private final class CancellableAuthenticationProviderOperation: Sendable {
    private let stream: AsyncThrowingStream<AuthenticationSession, Error>
    private let continuation: AsyncThrowingStream<AuthenticationSession, Error>.Continuation
    private let providerTask: Task<Void, Never>

    init(operation: @escaping @Sendable () async throws -> AuthenticationSession) {
        let pair = AsyncThrowingStream<AuthenticationSession, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = pair.stream
        continuation = pair.continuation
        providerTask = Task.detached {
            do {
                let session = try await operation()
                pair.continuation.yield(session)
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
    }

    func value() async throws -> AuthenticationSession {
        try await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            guard let session = try await iterator.next() else {
                throw CancellationError()
            }
            return session
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        providerTask.cancel()
        continuation.finish(throwing: CancellationError())
    }
}
