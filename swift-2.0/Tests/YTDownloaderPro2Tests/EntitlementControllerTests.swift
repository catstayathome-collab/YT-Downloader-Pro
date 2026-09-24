import Foundation
import XCTest
@testable import YTDownloaderPro2

@MainActor
final class EntitlementControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testRefreshVerifiesPersistsAndAppliesPro() async throws {
        let signer = EntitlementTestSigner()
        let token = try signedToken(signer: signer, subject: "account-a", revision: 7)
        let fetcher = ScriptedEntitlementFetcher(results: [.success(token)])
        let fixture = makeFixture(fetcher: fetcher, signer: signer)

        await fixture.controller.refresh(accessToken: "access", subject: "account-a")

        XCTAssertEqual(fixture.plan.currentPlan, .pro)
        XCTAssertEqual(fixture.controller.status, .verified(lastVerifiedAt: now))
        let cached = try await fixture.store.load(environment: .staging)
        let persisted = try await fixture.rawVault.load(environment: .staging)
        XCTAssertEqual(cached?.grantRevision, 7)
        XCTAssertEqual(persisted, token)
    }

    func testVerifiedProAutomaticallyReturnsToFreeAtTokenExpiry() async throws {
        let signer = EntitlementTestSigner()
        let token = try signedToken(
            signer: signer,
            subject: "account-a",
            revision: 7,
            expiresAt: 2_000_100
        )
        let sleeper = ControlledEntitlementExpirySleeper()
        let fixture = makeFixture(
            fetcher: ScriptedEntitlementFetcher(results: [.success(token)]),
            signer: signer,
            sleepUntil: { deadline in try await sleeper.sleep(until: deadline) }
        )

        await fixture.controller.refresh(accessToken: "access", subject: "account-a")

        let scheduledDeadline = await sleeper.waitForDeadline()
        XCTAssertEqual(scheduledDeadline, Date(timeIntervalSince1970: 2_000_100))
        XCTAssertEqual(fixture.plan.currentPlan, .pro)

        await sleeper.fire()
        await waitUntil { fixture.plan.currentPlan == .free }

        XCTAssertEqual(fixture.plan.currentPlan, .free)
        XCTAssertEqual(fixture.controller.status, .free)
    }

    func testOfflineGraceAutomaticallyReturnsToFreeAtGraceDeadline() async throws {
        let signer = EntitlementTestSigner()
        let token = try signedToken(
            signer: signer,
            subject: "account-a",
            revision: 7,
            issuedAt: 1_900_000,
            expiresAt: 1_999_900
        )
        let rawVault = InMemoryEntitlementVault()
        try await rawVault.save(token, environment: .staging)
        let sleeper = ControlledEntitlementExpirySleeper()
        let fixture = makeFixture(
            fetcher: ScriptedEntitlementFetcher(results: []),
            signer: signer,
            rawVault: rawVault,
            sleepUntil: { deadline in try await sleeper.sleep(until: deadline) }
        )

        await fixture.controller.restore(subject: "account-a")

        let scheduledDeadline = await sleeper.waitForDeadline()
        XCTAssertEqual(
            scheduledDeadline,
            Date(timeIntervalSince1970: 1_999_900 + VerifiedEntitlement.offlineGraceDuration)
        )
        XCTAssertEqual(fixture.plan.currentPlan, .pro)

        await sleeper.fire()
        await waitUntil { fixture.plan.currentPlan == .free }

        XCTAssertEqual(fixture.plan.currentPlan, .free)
        XCTAssertEqual(fixture.controller.status, .free)
    }

    func testUnauthorizedRefreshesAuthenticationAtMostOnce() async throws {
        let signer = EntitlementTestSigner()
        let fetcher = ScriptedEntitlementFetcher(results: [
            .failure(.unauthorized), .failure(.unauthorized)
        ])
        let fixture = makeFixture(fetcher: fetcher, signer: signer)
        let auth = EntitlementRefreshProbe(
            current: .init(subject: "account-a", accessToken: "old"),
            refreshed: .success(.init(subject: "account-a", accessToken: "new"))
        )

        await fixture.controller.refresh(using: auth)

        let requestCount = await fetcher.requestCount
        XCTAssertEqual(auth.refreshCount, 1)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(fixture.controller.status, .requiresReauthentication)
        XCTAssertEqual(fixture.plan.currentPlan, .free)
    }

    func testLateAccountAResponseCannotApplyAfterAccountBStarts() async throws {
        let signer = EntitlementTestSigner()
        let fetcher = ControlledEntitlementFetcher()
        let fixture = makeFixture(fetcher: fetcher, signer: signer)
        let proA = try signedToken(signer: signer, subject: "account-a", revision: 7)
        let freeB = try signedToken(signer: signer, subject: "account-b", plan: .free, revision: 0)

        let refreshA = Task { await fixture.controller.refresh(accessToken: "a", subject: "account-a") }
        await fetcher.waitForRequestCount(1)
        let refreshB = Task { await fixture.controller.refresh(accessToken: "b", subject: "account-b") }
        await fetcher.waitForRequestCount(2)
        await fetcher.complete(request: 1, with: .success(freeB))
        await refreshB.value
        await fetcher.complete(request: 0, with: .success(proA))
        await refreshA.value

        XCTAssertEqual(fixture.plan.currentPlan, .free)
        let cached = try await fixture.store.load(environment: .staging)
        XCTAssertEqual(cached?.subject, "account-b")
    }

    func testLowerRevisionCannotReplaceOrApplyOverNewerCachedGrant() async throws {
        let signer = EntitlementTestSigner()
        let revisionSeven = try signedToken(signer: signer, subject: "account-a", revision: 7)
        let revisionSix = try signedToken(signer: signer, subject: "account-a", revision: 6)
        let fetcher = ScriptedEntitlementFetcher(results: [
            .success(revisionSeven), .success(revisionSix)
        ])
        let fixture = makeFixture(fetcher: fetcher, signer: signer)

        await fixture.controller.refresh(accessToken: "access", subject: "account-a")
        await fixture.controller.refresh(accessToken: "access", subject: "account-a")

        XCTAssertEqual(fixture.plan.currentPlan, .pro)
        let cached = try await fixture.store.load(environment: .staging)
        XCTAssertEqual(cached?.grantRevision, 7)
    }

    func testNewVerifiedFreeDowngradesImmediately() async throws {
        let signer = EntitlementTestSigner()
        let pro = try signedToken(signer: signer, subject: "account-a", revision: 7)
        let free = try signedToken(signer: signer, subject: "account-a", plan: .free, revision: 8)
        let fetcher = ScriptedEntitlementFetcher(results: [.success(pro), .success(free)])
        let fixture = makeFixture(fetcher: fetcher, signer: signer)

        await fixture.controller.refresh(accessToken: "access", subject: "account-a")
        XCTAssertEqual(fixture.plan.currentPlan, .pro)

        await fixture.controller.refresh(accessToken: "access", subject: "account-a")

        XCTAssertEqual(fixture.plan.currentPlan, .free)
        XCTAssertEqual(fixture.controller.status, .verified(lastVerifiedAt: now))
    }

    func testRestoreUsesEligibleOfflineGraceAndDeletesBeyondGrace() async throws {
        let signer = EntitlementTestSigner()
        let graceToken = try signedToken(
            signer: signer,
            subject: "account-a",
            revision: 7,
            issuedAt: 1_900_000,
            expiresAt: 1_999_900
        )
        let rawVault = InMemoryEntitlementVault()
        try await rawVault.save(graceToken, environment: .staging)
        let graceFixture = makeFixture(
            fetcher: ScriptedEntitlementFetcher(results: []),
            signer: signer,
            rawVault: rawVault
        )

        await graceFixture.controller.restore(subject: "account-a")

        XCTAssertEqual(graceFixture.plan.currentPlan, .pro)
        XCTAssertEqual(
            graceFixture.controller.status,
            .offlineGrace(expiresAt: Date(timeIntervalSince1970: 1_999_900))
        )

        let expiredToken = try signedToken(
            signer: signer,
            subject: "account-a",
            revision: 8,
            issuedAt: 1_600_000,
            expiresAt: 1_700_000
        )
        try await rawVault.save(expiredToken, environment: .staging)
        let expiredFixture = makeFixture(
            fetcher: ScriptedEntitlementFetcher(results: []),
            signer: signer,
            rawVault: rawVault
        )

        await expiredFixture.controller.restore(subject: "account-a")

        let expiredCache = try await rawVault.load(environment: .staging)
        XCTAssertEqual(expiredFixture.plan.currentPlan, .free)
        XCTAssertNil(expiredCache)
    }

    func testNetworkFailurePreservesValidCachedGrantOtherwiseUsesFree() async throws {
        let signer = EntitlementTestSigner()
        let pro = try signedToken(signer: signer, subject: "account-a", revision: 7)
        let fetcher = ScriptedEntitlementFetcher(results: [
            .success(pro), .failure(.transportUnavailable)
        ])
        let fixture = makeFixture(fetcher: fetcher, signer: signer)

        await fixture.controller.refresh(accessToken: "access", subject: "account-a")
        await fixture.controller.refresh(accessToken: "access", subject: "account-a")

        XCTAssertEqual(fixture.plan.currentPlan, .pro)
        XCTAssertEqual(fixture.controller.status, .unavailableUsingCache)

        let emptyFixture = makeFixture(
            fetcher: ScriptedEntitlementFetcher(results: [.failure(.transportUnavailable)]),
            signer: signer
        )
        await emptyFixture.controller.refresh(accessToken: "access", subject: "account-a")
        XCTAssertEqual(emptyFixture.plan.currentPlan, .free)
        XCTAssertEqual(emptyFixture.controller.status, .unavailable)
    }

    func testMalformedCacheIsDeletedWithoutTouchingOtherState() async throws {
        let signer = EntitlementTestSigner()
        let rawVault = InMemoryEntitlementVault()
        try await rawVault.save("not-a-jws", environment: .staging)
        let fixture = makeFixture(
            fetcher: ScriptedEntitlementFetcher(results: []),
            signer: signer,
            rawVault: rawVault
        )

        await fixture.controller.restore(subject: "account-a")

        let cache = try await rawVault.load(environment: .staging)
        XCTAssertEqual(fixture.plan.currentPlan, .free)
        XCTAssertEqual(fixture.controller.status, .rejected)
        XCTAssertNil(cache)
    }

    private func makeFixture(
        fetcher: any EntitlementFetching,
        signer: EntitlementTestSigner,
        rawVault: InMemoryEntitlementVault = InMemoryEntitlementVault(),
        sleepUntil: @escaping @Sendable (Date) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(3_600))
        }
    ) -> ControllerFixture {
        let store = VerifiedEntitlementStore(vault: rawVault)
        let plan = PlanController(buildChannel: .publicRelease, provider: PublicFreePlanProvider())
        let fixedNow = now
        let controller = EntitlementController(
            environment: .staging,
            client: fetcher,
            verifier: EntitlementVerifier(),
            store: store,
            planController: plan,
            now: { fixedNow },
            sleepUntil: sleepUntil,
            verificationContext: { subject, now, cached in
                signer.context(subject: subject, now: now, acceptsCachedExpiry: cached)
            }
        )
        return ControllerFixture(controller: controller, plan: plan, store: store, rawVault: rawVault)
    }

    private func signedToken(
        signer: EntitlementTestSigner,
        subject: String,
        plan: EntitlementPlan = .pro,
        revision: Int,
        issuedAt: Int = 2_000_000,
        expiresAt: Int = 2_086_400
    ) throws -> String {
        var claims = signer.validClaims(subject: subject, now: Date(timeIntervalSince1970: TimeInterval(issuedAt)))
        claims["iat"] = issuedAt
        claims["nbf"] = issuedAt - 30
        claims["exp"] = expiresAt
        claims["grantRevision"] = revision
        if plan == .free {
            claims["plan"] = "free"
            claims["features"] = EntitlementSnapshot.syntheticFree.features.map(\.rawValue).sorted()
            claims["maxVideoHeight"] = 720
            claims["subscriptionState"] = "none"
        }
        return try signer.sign(claims: claims)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !predicate() {
            await Task.yield()
        }
    }
}

private struct ControllerFixture {
    let controller: EntitlementController
    let plan: PlanController
    let store: VerifiedEntitlementStore
    let rawVault: InMemoryEntitlementVault
}

private actor ScriptedEntitlementFetcher: EntitlementFetching {
    private var results: [Result<String, EntitlementClientError>]
    private(set) var requestCount = 0

    init(results: [Result<String, EntitlementClientError>]) {
        self.results = results
    }

    func fetch(accessToken: String) async throws -> String {
        requestCount += 1
        guard !results.isEmpty else { throw EntitlementClientError.transportUnavailable }
        return try results.removeFirst().get()
    }
}

private actor ControlledEntitlementFetcher: EntitlementFetching {
    private var continuations: [Int: CheckedContinuation<String, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requestCount = 0

    func fetch(accessToken: String) async throws -> String {
        let index = requestCount
        requestCount += 1
        let ready = waiters.filter { $0.0 <= requestCount }
        waiters.removeAll { $0.0 <= requestCount }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard requestCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func complete(request: Int, with result: Result<String, EntitlementClientError>) {
        let continuation = continuations.removeValue(forKey: request)
        switch result {
        case let .success(token): continuation?.resume(returning: token)
        case let .failure(error): continuation?.resume(throwing: error)
        }
    }
}

private actor ControlledEntitlementExpirySleeper {
    private var deadline: Date?
    private var continuation: CheckedContinuation<Void, Error>?

    func sleep(until deadline: Date) async throws {
        self.deadline = deadline
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitForDeadline() async -> Date {
        while deadline == nil {
            await Task.yield()
        }
        return deadline!
    }

    func fire() {
        continuation?.resume(returning: ())
        continuation = nil
    }
}

@MainActor
private final class EntitlementRefreshProbe: EntitlementSessionRefreshing {
    let current: EntitlementSessionContext?
    let refreshed: Result<EntitlementSessionContext, EntitlementSessionRefreshError>
    private(set) var refreshCount = 0

    init(
        current: EntitlementSessionContext?,
        refreshed: Result<EntitlementSessionContext, EntitlementSessionRefreshError>
    ) {
        self.current = current
        self.refreshed = refreshed
    }

    func entitlementSessionContext() -> EntitlementSessionContext? { current }

    func refreshEntitlementSession() async throws -> EntitlementSessionContext {
        refreshCount += 1
        return try refreshed.get()
    }
}
