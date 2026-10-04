import Combine
import Foundation

@MainActor
protocol AccountSessionObserving: EntitlementSessionRefreshing {
    var accountStatePublisher: AnyPublisher<AccountSessionState, Never> { get }
    func authenticatedContext() -> AuthenticatedSessionContext?
}

@MainActor
protocol AccountEntitlementControlling: AnyObject {
    func restore(subject: String) async
    func refresh(using authentication: any EntitlementSessionRefreshing) async
    func clear() async
}

extension EntitlementController: AccountEntitlementControlling {}

@MainActor
final class AccountEntitlementBridge {
    private let account: any AccountSessionObserving
    private let entitlement: any AccountEntitlementControlling
    private var observation: AnyCancellable?
    private var transitionTask: Task<Void, Never>?
    private var activeSubject: String?
    private var nextOperationID: UInt64 = 0

    init(
        account: any AccountSessionObserving,
        entitlement: any AccountEntitlementControlling
    ) {
        self.account = account
        self.entitlement = entitlement
    }

    func start() {
        guard observation == nil else { return }
        observation = account.accountStatePublisher.sink { [weak self] state in
            self?.receive(state)
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        invalidatePendingTransition()
    }

    func refreshCurrent() {
        guard let context = account.authenticatedContext() else { return }
        transitionToSignedIn(context)
    }

    private func receive(_ state: AccountSessionState) {
        switch state {
        case let .signedIn(summary):
            guard let context = account.authenticatedContext(),
                  context.accountID == summary.accountID else {
                transitionToSignedOutIfNeeded()
                return
            }
            transitionToSignedIn(context)
        case .disabled, .signedOut, .signingOut:
            transitionToSignedOutIfNeeded()
        case .requiresReauthentication:
            // A valid cache for the currently adopted subject remains independently usable.
            break
        case .signingIn, .restoring, .failed:
            // Transitional and bounded-error states cannot grant a new entitlement.
            break
        }
    }

    private func transitionToSignedIn(_ context: AuthenticatedSessionContext) {
        let subjectChanged = activeSubject != nil && activeSubject != context.accountID
        let isNewSubject = activeSubject != context.accountID
        activeSubject = context.accountID
        let operationID = beginTransition()

        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if subjectChanged {
                await entitlement.clear()
                guard owns(operationID) else { return }
            }
            if isNewSubject {
                await entitlement.restore(subject: context.accountID)
                guard owns(operationID) else { return }
            }
            guard account.authenticatedContext()?.accountID == context.accountID else { return }
            await entitlement.refresh(using: account)
        }
    }

    private func transitionToSignedOutIfNeeded() {
        guard activeSubject != nil else { return }
        activeSubject = nil
        let operationID = beginTransition()
        transitionTask = Task { @MainActor [weak self] in
            guard let self, owns(operationID) else { return }
            await entitlement.clear()
        }
    }

    private func beginTransition() -> UInt64 {
        transitionTask?.cancel()
        nextOperationID &+= 1
        return nextOperationID
    }

    private func invalidatePendingTransition() {
        transitionTask?.cancel()
        transitionTask = nil
        nextOperationID &+= 1
    }

    private func owns(_ operationID: UInt64) -> Bool {
        nextOperationID == operationID
    }
}

extension AccountSessionStore: AccountSessionObserving {
    var accountStatePublisher: AnyPublisher<AccountSessionState, Never> {
        $state.eraseToAnyPublisher()
    }
}
