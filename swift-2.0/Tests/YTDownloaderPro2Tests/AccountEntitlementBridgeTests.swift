import Combine
import Foundation
import XCTest
@testable import YTDownloaderPro2

@MainActor
final class AccountEntitlementBridgeTests: XCTestCase {
    func testSignedInStateRestoresThenRefreshesEntitlementForMatchingAccount() async {
        let account = BridgeAccountProbe()
        let entitlement = BridgeEntitlementProbe()
        let bridge = AccountEntitlementBridge(account: account, entitlement: entitlement)
        bridge.start()

        account.publishSignedIn(accountID: "account-a", accessToken: "access-a")
        await entitlement.waitForOperationCount(2)

        XCTAssertEqual(
            entitlement.operations,
            [.restore("account-a"), .refresh("account-a", "access-a")]
        )
        bridge.stop()
    }

    func testLogoutClearsAndLateRefreshCannotTriggerFurtherWork() async {
        let account = BridgeAccountProbe()
        let entitlement = BridgeEntitlementProbe(suspendsRefresh: true)
        let bridge = AccountEntitlementBridge(account: account, entitlement: entitlement)
        bridge.start()
        account.publishSignedIn(accountID: "account-a", accessToken: "access-a")
        await entitlement.waitForRefreshStart()

        account.publish(.signingOut)
        await entitlement.waitForClearCount(1)
        entitlement.finishSuspendedRefresh()
        await Task.yield()

        XCTAssertEqual(entitlement.clearCount, 1)
        XCTAssertEqual(entitlement.operations.last, .clear)
        bridge.stop()
    }

    func testSameAccountReauthenticationPreservesCacheButAccountChangeClearsFirst() async {
        let account = BridgeAccountProbe()
        let entitlement = BridgeEntitlementProbe()
        let bridge = AccountEntitlementBridge(account: account, entitlement: entitlement)
        bridge.start()
        account.publishSignedIn(accountID: "account-a", accessToken: "access-a")
        await entitlement.waitForOperationCount(2)

        account.publish(.requiresReauthentication(.google))
        await Task.yield()
        XCTAssertEqual(entitlement.clearCount, 0)

        account.publishSignedIn(accountID: "account-b", accessToken: "access-b")
        await entitlement.waitForOperationCount(5)

        XCTAssertEqual(
            entitlement.operations,
            [
                .restore("account-a"),
                .refresh("account-a", "access-a"),
                .clear,
                .restore("account-b"),
                .refresh("account-b", "access-b")
            ]
        )
        bridge.stop()
    }

    func testAppActivationRefreshesTheCurrentSignedInAccount() async {
        let account = BridgeAccountProbe()
        let entitlement = BridgeEntitlementProbe()
        let bridge = AccountEntitlementBridge(account: account, entitlement: entitlement)
        bridge.start()
        account.publishSignedIn(accountID: "account-a", accessToken: "access-a")
        await entitlement.waitForOperationCount(2)

        bridge.refreshCurrent()
        await entitlement.waitForOperationCount(3)

        XCTAssertEqual(
            entitlement.operations,
            [
                .restore("account-a"),
                .refresh("account-a", "access-a"),
                .refresh("account-a", "access-a")
            ]
        )
        bridge.stop()
    }

    func testStopCancelsObservationAndClearsNoStateByItself() async {
        let account = BridgeAccountProbe()
        let entitlement = BridgeEntitlementProbe()
        let bridge = AccountEntitlementBridge(account: account, entitlement: entitlement)
        bridge.start()
        bridge.stop()

        account.publishSignedIn(accountID: "account-a", accessToken: "access-a")
        await Task.yield()

        XCTAssertEqual(entitlement.operations, [])
    }
}

private enum BridgeEntitlementOperation: Equatable {
    case restore(String)
    case refresh(String, String)
    case clear
}

@MainActor
private final class BridgeAccountProbe: AccountSessionObserving {
    private let subject = CurrentValueSubject<AccountSessionState, Never>(.signedOut)
    private var context: AuthenticatedSessionContext?

    var accountStatePublisher: AnyPublisher<AccountSessionState, Never> {
        subject.eraseToAnyPublisher()
    }

    func publish(_ state: AccountSessionState) {
        if case .signedOut = state { context = nil }
        if case .signingOut = state { context = nil }
        subject.send(state)
    }

    func publishSignedIn(accountID: String, accessToken: String) {
        let expiresAt = Date(timeIntervalSince1970: 4_000_000_000)
        context = AuthenticatedSessionContext(
            accountID: accountID,
            accessToken: accessToken,
            expiresAt: expiresAt
        )
        subject.send(.signedIn(AccountSummary(
            provider: .google,
            accountID: accountID,
            displayName: "Test User",
            maskedEmail: "t•••@example.com",
            expiresAt: expiresAt
        )))
    }

    func authenticatedContext() -> AuthenticatedSessionContext? {
        context
    }

    func entitlementSessionContext() -> EntitlementSessionContext? {
        context.map { .init(subject: $0.accountID, accessToken: $0.accessToken) }
    }

    func refreshEntitlementSession() async throws -> EntitlementSessionContext {
        guard let value = entitlementSessionContext() else {
            throw EntitlementSessionRefreshError.unavailable
        }
        return value
    }
}

@MainActor
private final class BridgeEntitlementProbe: AccountEntitlementControlling {
    private(set) var operations: [BridgeEntitlementOperation] = []
    var clearCount: Int { operations.filter { $0 == .clear }.count }

    private let suspendsRefresh: Bool
    private var refreshStartWaiter: CheckedContinuation<Void, Never>?
    private var refreshFinishContinuation: CheckedContinuation<Void, Never>?
    private var operationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var clearWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(suspendsRefresh: Bool = false) {
        self.suspendsRefresh = suspendsRefresh
    }

    func restore(subject: String) async {
        append(.restore(subject))
    }

    func refresh(using authentication: any EntitlementSessionRefreshing) async {
        guard let context = authentication.entitlementSessionContext() else { return }
        append(.refresh(context.subject, context.accessToken))
        refreshStartWaiter?.resume()
        refreshStartWaiter = nil
        if suspendsRefresh {
            await withCheckedContinuation { continuation in
                refreshFinishContinuation = continuation
            }
        }
    }

    func clear() async {
        append(.clear)
    }

    func waitForRefreshStart() async {
        if operations.contains(where: {
            if case .refresh = $0 { return true }
            return false
        }) { return }
        await withCheckedContinuation { continuation in
            refreshStartWaiter = continuation
        }
    }

    func finishSuspendedRefresh() {
        refreshFinishContinuation?.resume()
        refreshFinishContinuation = nil
    }

    func waitForOperationCount(_ count: Int) async {
        guard operations.count < count else { return }
        await withCheckedContinuation { continuation in
            operationWaiters.append((count, continuation))
        }
    }

    func waitForClearCount(_ count: Int) async {
        guard clearCount < count else { return }
        await withCheckedContinuation { continuation in
            clearWaiters.append((count, continuation))
        }
    }

    private func append(_ operation: BridgeEntitlementOperation) {
        operations.append(operation)
        let satisfiedOperations = operationWaiters.filter { $0.0 <= operations.count }
        operationWaiters.removeAll { $0.0 <= operations.count }
        satisfiedOperations.forEach { $0.1.resume() }
        let satisfiedClears = clearWaiters.filter { $0.0 <= clearCount }
        clearWaiters.removeAll { $0.0 <= clearCount }
        satisfiedClears.forEach { $0.1.resume() }
    }
}
