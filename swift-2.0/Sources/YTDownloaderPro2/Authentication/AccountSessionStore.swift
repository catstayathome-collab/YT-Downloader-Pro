import Combine
import Foundation

@MainActor
final class AccountSessionStore: ObservableObject, EntitlementSessionRefreshing {
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
    private var authenticationCancellationIsAuthorized = false
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
        self.state = environment.supportsAuthentication ? .signedOut : .disabled
    }

    static func live(
        resolution: AuthEnvironmentResolution = .resolve(configuration: nil)
    ) -> AccountSessionStore {
        let providers: AuthenticationProviderRegistry = switch resolution.environment {
        case .mock:
            .mock()
        case .staging:
            if let configuration = resolution.configuration {
                .init([SupabaseGoogleAuthenticationProvider(configuration: configuration)])
            } else {
                .init([])
            }
        case .disabled, .production:
            .init([])
        }
        return AccountSessionStore(
            environment: resolution.environment,
            vault: KeychainCredentialVault(),
            providers: providers
        )
    }

    func signIn(with kind: AuthenticationProviderKind) async {
        guard environment.supportsAuthentication else { return }
        guard let (operationID, priorState) = beginOperation() else { return }
        state = .signingIn(kind)
        authenticationCancellationIsAuthorized = true
        isAuthenticationCancellationAvailable = true
        guard owns(operationID) else {
            isAuthenticationCancellationAvailable = false
            return
        }
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
        guard environment.supportsAuthentication else {
            state = .disabled
            return
        }
        guard currentSummary == nil else { return }
        guard let (operationID, priorState) = beginOperation() else { return }
        state = .restoring
        authenticationCancellationIsAuthorized = true
        isAuthenticationCancellationAvailable = true
        guard owns(operationID) else {
            isAuthenticationCancellationAvailable = false
            return
        }
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
              authenticationCancellationIsAuthorized,
              activeOperationID != nil else { return }
        let priorState = activePriorState ?? (environment.supportsAuthentication ? .signedOut : .disabled)
        authenticationCancellationIsAuthorized = false
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
        guard environment.supportsAuthentication,
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
            finishCredentialRemovalFailure(operationID)
        }
    }

    func retryCredentialRemoval() async {
        guard environment.supportsAuthentication,
              activeOperationID == nil,
              state == .failed(.credentialRemovalFailed),
              let (operationID, _) = beginOperation() else { return }
        state = currentSummary == nil ? .restoring : .signingOut
        guard beginCredentialCommit(operationID) else { return }
        do {
            try await deleteCredential()
            guard owns(operationID) else { return }
            finishCredentialRemoval(operationID)
        } catch {
            guard owns(operationID) else { return }
            finishCredentialRemovalFailure(operationID)
        }
    }

    func authenticatedContext() -> AuthenticatedSessionContext? {
        guard case let .signedIn(stateSummary) = state,
              let summary = currentSummary,
              stateSummary == summary,
              let accessToken,
              hasOpaqueContent(accessToken),
              summary.expiresAt > now() else {
            return nil
        }
        return AuthenticatedSessionContext(
            accountID: summary.accountID,
            accessToken: accessToken,
            expiresAt: summary.expiresAt
        )
    }

    func refreshAuthenticatedSession() async throws -> AuthenticatedSessionContext {
        guard environment.supportsAuthentication,
              activeOperationID == nil,
              case let .signedIn(stateSummary) = state,
              let previousSummary = currentSummary,
              stateSummary == previousSummary,
              let refreshCredential,
              let provider = providers.provider(for: previousSummary.provider),
              let (operationID, priorState) = beginOperation() else {
            throw AuthenticationProviderError.invalidSession
        }

        state = .restoring
        let envelope = StoredCredentialEnvelope(
            summary: previousSummary,
            refreshCredential: refreshCredential
        )
        let providerOperation = CancellableAuthenticationProviderOperation {
            try await provider.restore(from: envelope)
        }
        activeProviderOperation = providerOperation

        do {
            let session = try await providerOperation.value()
            guard owns(operationID) else { throw AuthenticationProviderError.cancelled }
            try validate(session, provider: previousSummary.provider)
            guard session.summary.accountID == previousSummary.accountID else {
                throw AuthenticationProviderError.invalidSession
            }
            guard beginCredentialCommit(operationID) else {
                throw AuthenticationProviderError.cancelled
            }
            try await saveCredential(session.storedEnvelope)
            guard owns(operationID) else { throw AuthenticationProviderError.cancelled }
            accessToken = session.accessToken
            self.refreshCredential = session.refreshCredential
            currentSummary = session.summary
            finishOperation(operationID, state: .signedIn(session.summary))
            return AuthenticatedSessionContext(
                accountID: session.summary.accountID,
                accessToken: session.accessToken,
                expiresAt: session.summary.expiresAt
            )
        } catch {
            guard owns(operationID) else { throw AuthenticationProviderError.cancelled }
            accessToken = nil
            switch error {
            case is CancellationError, AuthenticationProviderError.cancelled:
                finishOperation(operationID, state: priorState)
                throw AuthenticationProviderError.cancelled
            case AuthenticationProviderError.expiredSession:
                finishOperation(
                    operationID,
                    state: .requiresReauthentication(previousSummary.provider)
                )
                throw AuthenticationProviderError.expiredSession
            case AuthenticationProviderError.invalidSession:
                finishOperation(
                    operationID,
                    state: .requiresReauthentication(previousSummary.provider)
                )
                throw AuthenticationProviderError.invalidSession
            case AuthenticationProviderError.temporarilyUnavailable:
                finishOperation(operationID, state: .failed(.signInFailed))
                throw AuthenticationProviderError.temporarilyUnavailable
            case is CredentialVaultError:
                finishOperation(operationID, state: .failed(.credentialStorageUnavailable))
                throw error
            default:
                finishOperation(
                    operationID,
                    state: .requiresReauthentication(previousSummary.provider)
                )
                throw AuthenticationProviderError.invalidSession
            }
        }
    }

    func entitlementSessionContext() -> EntitlementSessionContext? {
        authenticatedContext().map {
            EntitlementSessionContext(subject: $0.accountID, accessToken: $0.accessToken)
        }
    }

    func refreshEntitlementSession() async throws -> EntitlementSessionContext {
        let context = try await refreshAuthenticatedSession()
        return EntitlementSessionContext(
            subject: context.accountID,
            accessToken: context.accessToken
        )
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
        authenticationCancellationIsAuthorized = false
        activeOperationID = nil
        activePriorState = nil
        activeProviderOperation = nil
        isAuthenticationCancellationAvailable = false
        state = newState
    }

    private func beginCredentialCommit(_ operationID: UInt64) -> Bool {
        guard owns(operationID) else { return false }
        activeProviderOperation = nil
        authenticationCancellationIsAuthorized = false
        isAuthenticationCancellationAvailable = false
        return owns(operationID)
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
        case AuthenticationProviderError.temporarilyUnavailable:
            finishOperation(operationID, state: .failed(.signInFailed))
            recordDiagnostic(.signInFailed)
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
            finishCredentialRemoval(operationID)
        } catch {
            guard owns(operationID) else { return }
            finishCredentialRemovalFailure(operationID)
        }
    }

    private func finishCredentialRemoval(_ operationID: UInt64) {
        guard owns(operationID) else { return }
        guard currentSummary != nil else {
            finishOperation(operationID, state: .requiresReauthentication(nil))
            return
        }
        refreshCredential = nil
        currentSummary = nil
        finishOperation(operationID, state: .signedOut)
        recordDiagnostic(.signOutCompleted)
    }

    private func finishCredentialRemovalFailure(_ operationID: UInt64) {
        guard owns(operationID) else { return }
        finishOperation(operationID, state: .failed(.credentialRemovalFailed))
        recordDiagnostic(.storageUnavailable)
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
        case AuthenticationProviderError.temporarilyUnavailable:
            .signInFailed
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
