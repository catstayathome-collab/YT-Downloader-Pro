import Combine
import Foundation

@MainActor
final class AccountSessionStore: ObservableObject {
    @Published private(set) var state: AccountSessionState
    let environment: AuthEnvironment

    private let vault: any CredentialVault
    private let providers: AuthenticationProviderRegistry
    private let now: @Sendable () -> Date
    private var accessToken: String?
    private var refreshCredential: String?
    private var currentSummary: AccountSummary?
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?
    private var activePriorState: AccountSessionState?
    private var activeProviderTask: Task<AuthenticationSession, Error>?

    init(
        environment: AuthEnvironment,
        vault: any CredentialVault,
        providers: AuthenticationProviderRegistry,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.vault = vault
        self.providers = providers
        self.now = now
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
        guard environment == .mock,
              let provider = providers.provider(for: kind) else {
            if environment == .mock {
                state = .failed(.providerUnavailable)
            }
            return
        }
        guard let (operationID, priorState) = beginOperation() else { return }
        state = .signingIn(kind)
        let task = Task { try await provider.signIn() }
        activeProviderTask = task
        let result = await task.result
        guard owns(operationID) else { return }

        do {
            let session = try result.get()
            try validate(session, provider: kind)
            try await vault.save(session.storedEnvelope, environment: environment)
            guard owns(operationID) else { return }
            accessToken = session.accessToken
            refreshCredential = session.refreshCredential
            currentSummary = session.summary
            finishOperation(operationID, state: .signedIn(session.summary))
        } catch is CancellationError {
            finishOperation(operationID, state: priorState)
        } catch AuthenticationProviderError.cancelled {
            finishOperation(operationID, state: priorState)
        } catch {
            finishOperation(operationID, state: .failed(presentationError(for: error)))
        }
    }

    func restoreSession() async {
        guard environment == .mock else {
            state = .disabled
            return
        }
        guard let (operationID, priorState) = beginOperation() else { return }
        state = .restoring
        var restoringProvider: AuthenticationProviderKind?

        do {
            guard let envelope = try await vault.load(environment: environment) else {
                finishOperation(operationID, state: .signedOut)
                return
            }
            restoringProvider = envelope.summary.provider
            guard owns(operationID),
                  let provider = providers.provider(for: envelope.summary.provider) else {
                if owns(operationID) {
                    finishOperation(operationID, state: .requiresReauthentication(nil))
                }
                return
            }
            let task = Task { try await provider.restore(from: envelope) }
            activeProviderTask = task
            let session = try await task.value
            guard owns(operationID) else { return }
            try validate(session, provider: envelope.summary.provider)
            accessToken = session.accessToken
            refreshCredential = session.refreshCredential
            currentSummary = session.summary
            finishOperation(operationID, state: .signedIn(session.summary))
        } catch is CancellationError {
            finishOperation(operationID, state: priorState)
        } catch AuthenticationProviderError.cancelled {
            finishOperation(operationID, state: priorState)
        } catch AuthenticationProviderError.expiredSession {
            finishOperation(operationID, state: .requiresReauthentication(restoringProvider))
        } catch AuthenticationProviderError.invalidSession {
            do {
                try await vault.delete(environment: environment)
            } catch {
                guard owns(operationID) else { return }
                finishOperation(operationID, state: .failed(.credentialRemovalFailed))
                return
            }
            guard owns(operationID) else { return }
            finishOperation(operationID, state: .requiresReauthentication(nil))
        } catch CredentialVaultError.malformedRecord {
            do {
                try await vault.delete(environment: environment)
            } catch {
                guard owns(operationID) else { return }
                finishOperation(operationID, state: .failed(.credentialRemovalFailed))
                return
            }
            guard owns(operationID) else { return }
            finishOperation(operationID, state: .requiresReauthentication(nil))
        } catch {
            finishOperation(operationID, state: .failed(.credentialStorageUnavailable))
        }
    }

    func cancelAuthentication() {
        let isCancellable = switch state {
        case .signingIn, .restoring:
            true
        default:
            false
        }
        guard isCancellable, let operationID = activeOperationID else { return }
        let priorState = activePriorState ?? (environment == .disabled ? .disabled : .signedOut)
        activeProviderTask?.cancel()
        finishOperation(operationID, state: priorState)
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
        do {
            try await vault.delete(environment: environment)
            guard owns(operationID) else { return }
            refreshCredential = nil
            currentSummary = nil
            finishOperation(operationID, state: .signedOut)
        } catch {
            finishOperation(operationID, state: .failed(.credentialRemovalFailed))
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
        activeProviderTask = nil
        state = newState
    }

    private func validate(
        _ session: AuthenticationSession,
        provider: AuthenticationProviderKind
    ) throws {
        guard session.summary.provider == provider,
              !session.summary.accountID.isEmpty,
              !session.summary.displayName.isEmpty,
              !session.accessToken.isEmpty,
              !session.refreshCredential.isEmpty else {
            throw AuthenticationProviderError.invalidSession
        }
        guard session.summary.expiresAt > now() else {
            throw AuthenticationProviderError.expiredSession
        }
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
