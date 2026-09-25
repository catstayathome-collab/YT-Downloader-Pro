import Combine
import CryptoKit
import Foundation

enum EntitlementStatus: Equatable, Sendable {
    case free
    case refreshing
    case verified(lastVerifiedAt: Date)
    case offlineGrace(expiresAt: Date)
    case unavailable
    case unavailableUsingCache
    case rejected
    case rejectedUsingCache
    case requiresReauthentication
}

struct EntitlementSessionContext: Equatable, Sendable {
    let subject: String
    let accessToken: String
}

enum EntitlementSessionRefreshError: Error, Equatable, Sendable {
    case unavailable
}

@MainActor
protocol EntitlementSessionRefreshing: AnyObject {
    func entitlementSessionContext() -> EntitlementSessionContext?
    func refreshEntitlementSession() async throws -> EntitlementSessionContext
}

@MainActor
final class EntitlementController: ObservableObject {
    typealias VerificationContextBuilder = @Sendable (
        _ subject: String,
        _ now: Date,
        _ acceptsCachedExpiry: Bool
    ) -> EntitlementVerificationContext
    typealias ExpirySleeper = @Sendable (_ deadline: Date) async throws -> Void

    @Published private(set) var status: EntitlementStatus = .free

    private let environment: AuthEnvironment
    private let client: any EntitlementFetching
    private let verifier: any EntitlementVerifying
    private let store: VerifiedEntitlementStore
    private let planController: PlanController
    private let now: @Sendable () -> Date
    private let sleepUntil: ExpirySleeper
    private let verificationContext: VerificationContextBuilder
    private var nextOperationID: UInt64 = 0
    private var activeSubject: String?
    private var expiryTask: Task<Void, Never>?

    init(
        environment: AuthEnvironment,
        client: any EntitlementFetching,
        verifier: any EntitlementVerifying,
        store: VerifiedEntitlementStore,
        planController: PlanController,
        now: @escaping @Sendable () -> Date = { Date() },
        sleepUntil: @escaping ExpirySleeper = { deadline in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
        },
        verificationContext: @escaping VerificationContextBuilder
    ) {
        self.environment = environment
        self.client = client
        self.verifier = verifier
        self.store = store
        self.planController = planController
        self.now = now
        self.sleepUntil = sleepUntil
        self.verificationContext = verificationContext
    }

    deinit {
        expiryTask?.cancel()
    }

    static func live(
        resolution: AuthEnvironmentResolution,
        planController: PlanController
    ) -> EntitlementController {
        let configuration = resolution.configuration
        let keys = configuration?.publicKeys.reduce(into: [String: P256.Signing.PublicKey]()) {
            result, entry in
            if let key = try? P256.Signing.PublicKey(x963Representation: entry.value) {
                result[entry.key] = key
            }
        } ?? [:]
        let client: any EntitlementFetching = if let configuration {
            EntitlementClient(endpoint: configuration.entitlementURL)
        } else {
            UnavailableEntitlementFetcher()
        }

        return EntitlementController(
            environment: resolution.environment,
            client: client,
            verifier: EntitlementVerifier(),
            store: VerifiedEntitlementStore(vault: KeychainEntitlementVault()),
            planController: planController
        ) { subject, now, acceptsCachedExpiry in
            EntitlementVerificationContext(
                issuer: configuration?.entitlementIssuer ?? "",
                audience: configuration?.entitlementAudience ?? "",
                subject: subject,
                now: now,
                allowedClockSkew: 5 * 60,
                acceptedExpiryGrace: acceptsCachedExpiry ? VerifiedEntitlement.offlineGraceDuration : 0,
                publicKeys: keys
            )
        }
    }

    func restore(subject: String) async {
        let operationID = await beginOperation(subject: subject)
        guard owns(operationID) else { return }
        do {
            guard let token = try await store.compactToken(environment: environment) else {
                applyFree(status: .free, operationID: operationID)
                return
            }
            let currentTime = now()
            let verified = try verifier.verify(
                token: token,
                context: verificationContext(subject, currentTime, true)
            )
            guard owns(operationID), verified.subject == subject else {
                if owns(operationID) { await rejectCachedToken(operationID: operationID) }
                return
            }
            try await store.adopt(verified, environment: environment)
            guard owns(operationID) else { return }
            switch verified.use(at: currentTime, allowOfflineGrace: true) {
            case .current:
                apply(verified, status: .verified(lastVerifiedAt: currentTime), operationID: operationID)
            case .offlineGrace:
                apply(
                    verified,
                    status: .offlineGrace(expiresAt: verified.deadline(allowOfflineGrace: true)),
                    operationID: operationID
                )
            case .expired:
                await rejectCachedToken(operationID: operationID)
            }
        } catch {
            guard owns(operationID) else { return }
            await rejectCachedToken(operationID: operationID)
        }
    }

    func refresh(accessToken: String, subject: String) async {
        let operationID = await beginOperation(subject: subject)
        guard owns(operationID) else { return }
        status = .refreshing
        await fetchVerifyAndAdopt(
            accessToken: accessToken,
            subject: subject,
            operationID: operationID,
            failureStatus: .unavailable
        )
    }

    func refresh(using authentication: any EntitlementSessionRefreshing) async {
        guard let initial = authentication.entitlementSessionContext() else {
            await clear()
            status = .requiresReauthentication
            return
        }
        let operationID = await beginOperation(subject: initial.subject)
        guard owns(operationID) else { return }
        status = .refreshing

        do {
            let token = try await client.fetch(accessToken: initial.accessToken)
            await verifyAndAdopt(token: token, subject: initial.subject, operationID: operationID)
        } catch EntitlementClientError.unauthorized {
            guard owns(operationID) else { return }
            do {
                let refreshed = try await authentication.refreshEntitlementSession()
                guard owns(operationID), refreshed.subject == initial.subject else {
                    applyFree(status: .requiresReauthentication, operationID: operationID)
                    return
                }
                let token = try await client.fetch(accessToken: refreshed.accessToken)
                await verifyAndAdopt(token: token, subject: refreshed.subject, operationID: operationID)
            } catch {
                guard owns(operationID) else { return }
                await fallback(
                    subject: initial.subject,
                    operationID: operationID,
                    withoutCache: .requiresReauthentication,
                    withCache: .requiresReauthentication
                )
            }
        } catch EntitlementClientError.cancelled {
            await fallback(
                subject: initial.subject,
                operationID: operationID,
                withoutCache: .free,
                withCache: .unavailableUsingCache
            )
        } catch {
            await fallback(
                subject: initial.subject,
                operationID: operationID,
                withoutCache: .unavailable,
                withCache: .unavailableUsingCache
            )
        }
    }

    func clear() async {
        expiryTask?.cancel()
        expiryTask = nil
        nextOperationID &+= 1
        activeSubject = nil
        planController.clearVerifiedEntitlement()
        status = .free
        try? await store.delete(environment: environment)
    }

    private func beginOperation(subject: String) async -> UInt64 {
        expiryTask?.cancel()
        expiryTask = nil
        nextOperationID &+= 1
        let operationID = nextOperationID
        if let activeSubject, activeSubject != subject {
            self.activeSubject = subject
            planController.clearVerifiedEntitlement()
            status = .free
            try? await store.delete(environment: environment)
        } else {
            activeSubject = subject
        }
        return operationID
    }

    private func owns(_ operationID: UInt64) -> Bool {
        nextOperationID == operationID
    }

    private func fetchVerifyAndAdopt(
        accessToken: String,
        subject: String,
        operationID: UInt64,
        failureStatus: EntitlementStatus
    ) async {
        do {
            let token = try await client.fetch(accessToken: accessToken)
            await verifyAndAdopt(token: token, subject: subject, operationID: operationID)
        } catch EntitlementClientError.unauthorized {
            await fallback(
                subject: subject,
                operationID: operationID,
                withoutCache: .requiresReauthentication,
                withCache: .requiresReauthentication
            )
        } catch EntitlementClientError.cancelled {
            await fallback(
                subject: subject,
                operationID: operationID,
                withoutCache: .free,
                withCache: .unavailableUsingCache
            )
        } catch {
            await fallback(
                subject: subject,
                operationID: operationID,
                withoutCache: failureStatus,
                withCache: .unavailableUsingCache
            )
        }
    }

    private func verifyAndAdopt(token: String, subject: String, operationID: UInt64) async {
        guard owns(operationID) else { return }
        let currentTime = now()
        do {
            let verified = try verifier.verify(
                token: token,
                context: verificationContext(subject, currentTime, false)
            )
            guard verified.use(at: currentTime, allowOfflineGrace: false) == .current else {
                throw EntitlementVerificationError.invalidClaims
            }
            try await store.adopt(verified, environment: environment)
            guard owns(operationID),
                  let adopted = try await store.load(environment: environment),
                  adopted.subject == subject else { return }
            apply(adopted, status: .verified(lastVerifiedAt: currentTime), operationID: operationID)
        } catch {
            guard owns(operationID) else { return }
            await fallback(
                subject: subject,
                operationID: operationID,
                withoutCache: .rejected,
                withCache: .rejectedUsingCache
            )
        }
    }

    private func fallback(
        subject: String,
        operationID: UInt64,
        withoutCache: EntitlementStatus,
        withCache: EntitlementStatus
    ) async {
        guard owns(operationID) else { return }
        do {
            guard let cached = try await store.load(environment: environment),
                  cached.subject == subject else {
                applyFree(status: withoutCache, operationID: operationID)
                return
            }
            guard owns(operationID) else { return }
            switch cached.use(at: now(), allowOfflineGrace: true) {
            case .current:
                apply(cached, status: withCache, operationID: operationID)
            case .offlineGrace:
                apply(
                    cached,
                    status: .offlineGrace(expiresAt: cached.deadline(allowOfflineGrace: true)),
                    operationID: operationID
                )
            case .expired:
                try? await store.delete(environment: environment)
                applyFree(status: withoutCache, operationID: operationID)
            }
        } catch {
            applyFree(status: withoutCache, operationID: operationID)
        }
    }

    private func rejectCachedToken(operationID: UInt64) async {
        try? await store.delete(environment: environment)
        applyFree(status: .rejected, operationID: operationID)
    }

    private func apply(
        _ entitlement: VerifiedEntitlement,
        status: EntitlementStatus,
        operationID: UInt64
    ) {
        guard owns(operationID) else { return }
        planController.applyVerifiedEntitlement(entitlement)
        self.status = status
        scheduleExpiry(for: entitlement, status: status, operationID: operationID)
    }

    private func applyFree(status: EntitlementStatus, operationID: UInt64) {
        guard owns(operationID) else { return }
        expiryTask?.cancel()
        expiryTask = nil
        planController.clearVerifiedEntitlement()
        self.status = status
    }

    private func scheduleExpiry(
        for entitlement: VerifiedEntitlement,
        status: EntitlementStatus,
        operationID: UInt64
    ) {
        expiryTask?.cancel()
        expiryTask = nil
        guard entitlement.snapshot.plan == .pro else { return }

        let allowsOfflineGrace: Bool = switch status {
        case .offlineGrace, .unavailableUsingCache, .rejectedUsingCache:
            true
        default:
            false
        }
        let deadline = entitlement.deadline(allowOfflineGrace: allowsOfflineGrace)
        let sleepUntil = sleepUntil
        let subject = entitlement.subject
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await sleepUntil(deadline)
            } catch {
                return
            }
            guard let self,
                  owns(operationID),
                  activeSubject == subject else { return }
            planController.clearVerifiedEntitlement()
            self.status = .free
            expiryTask = nil
        }
    }
}

private struct UnavailableEntitlementFetcher: EntitlementFetching {
    func fetch(accessToken: String) async throws -> String {
        throw EntitlementClientError.transportUnavailable
    }
}
