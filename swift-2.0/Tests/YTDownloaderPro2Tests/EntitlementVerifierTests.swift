import CryptoKit
import Foundation
import XCTest
@testable import YTDownloaderPro2

final class EntitlementVerifierTests: XCTestCase {
    private let fixtureSubject = "11111111-1111-1111-1111-111111111111"
    private let fixtureNow = Date(timeIntervalSince1970: 1_790_208_100)

    func testDenoFixtureVerifiesToExactProSnapshotAndStrictUseBoundaries() throws {
        let verified = try EntitlementVerifier().verify(
            token: try entitlementFixtureJWS(),
            context: try entitlementFixtureContext(subject: fixtureSubject, now: fixtureNow)
        )

        XCTAssertEqual(verified.subject, fixtureSubject)
        XCTAssertEqual(verified.grantRevision, 7)
        XCTAssertEqual(verified.snapshot, .syntheticPro)
        XCTAssertEqual(
            verified.use(at: verified.expiresAt.addingTimeInterval(-1), allowOfflineGrace: false),
            .current
        )
        XCTAssertEqual(verified.use(at: verified.expiresAt, allowOfflineGrace: false), .expired)
        XCTAssertEqual(verified.use(at: verified.expiresAt, allowOfflineGrace: true), .offlineGrace)
        XCTAssertEqual(
            verified.use(
                at: verified.expiresAt.addingTimeInterval(VerifiedEntitlement.offlineGraceDuration),
                allowOfflineGrace: true
            ),
            .offlineGrace
        )
        XCTAssertEqual(
            verified.use(
                at: verified.expiresAt.addingTimeInterval(VerifiedEntitlement.offlineGraceDuration + 1),
                allowOfflineGrace: true
            ),
            .expired
        )
    }

    func testVerifierRejectsUnsignedMalformedAndCrossAccountTokens() throws {
        let fixture = try entitlementFixtureJWS()
        let segments = fixture.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let context = try entitlementFixtureContext(subject: fixtureSubject, now: fixtureNow)
        let wrongSubject = try entitlementFixtureContext(subject: UUID().uuidString, now: fixtureNow)
        let noneHeader = try entitlementBase64URL([
            "alg": "none", "kid": "test-es256-2026-09", "typ": "JWT"
        ])
        let unknownKeyHeader = try entitlementBase64URL([
            "alg": "ES256", "kid": "unknown", "typ": "JWT"
        ])

        let mutations = [
            "\(noneHeader).\(segments[1]).\(segments[2])",
            "\(unknownKeyHeader).\(segments[1]).\(segments[2])",
            "\(segments[0]).\(segments[1]).\(String(segments[2].dropLast()) + (segments[2].last == "A" ? "B" : "A"))",
            "\(segments[0])=.\(segments[1]).\(segments[2])",
            fixture + ".extra",
            ".\(segments[1]).\(segments[2])"
        ]

        XCTAssertThrowsError(try EntitlementVerifier().verify(token: fixture, context: wrongSubject))
        for token in mutations {
            XCTAssertThrowsError(try EntitlementVerifier().verify(token: token, context: context), token)
        }
    }

    func testVerifierRejectsEverySignedClaimTrustBoundary() throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let context = signer.context(subject: fixtureSubject, now: now)
        let valid = signer.validClaims(subject: fixtureSubject, now: now)
        let mutations: [(String, [String: Any])] = [
            ("issuer", valid.merging(["iss": "https://issuer.invalid"]) { _, new in new }),
            ("audience", valid.merging(["aud": "wrong-audience"]) { _, new in new }),
            ("subject", valid.merging(["sub": UUID().uuidString]) { _, new in new }),
            ("not-before", valid.merging(["nbf": 2_000_301]) { _, new in new }),
            ("expired", valid.merging(["exp": 1_999_699]) { _, new in new }),
            ("schema", valid.merging(["schema": 2]) { _, new in new }),
            ("plan-feature", valid.merging(["features": ["download.single"]]) { _, new in new }),
            ("height", valid.merging(["maxVideoHeight": 1_080]) { _, new in new }),
            ("revision", valid.merging(["grantRevision": 0]) { _, new in new })
        ]

        for (name, claims) in mutations {
            XCTAssertThrowsError(
                try EntitlementVerifier().verify(token: try signer.sign(claims: claims), context: context),
                name
            )
        }
    }

    func testVerifierAcceptsFiveMinuteClaimSkewButDoesNotExtendBusinessExpiry() throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let context = signer.context(subject: fixtureSubject, now: now)

        var futureClaims = signer.validClaims(subject: fixtureSubject, now: now)
        futureClaims["iat"] = 2_000_300
        futureClaims["nbf"] = 2_000_300
        futureClaims["exp"] = 2_086_700
        XCTAssertNoThrow(
            try EntitlementVerifier().verify(token: try signer.sign(claims: futureClaims), context: context)
        )

        var expiredClaims = signer.validClaims(subject: fixtureSubject, now: now)
        expiredClaims["iat"] = 1_900_000
        expiredClaims["nbf"] = 1_899_970
        expiredClaims["exp"] = 1_999_700
        let expired = try EntitlementVerifier().verify(
            token: try signer.sign(claims: expiredClaims),
            context: context
        )
        XCTAssertEqual(expired.use(at: now, allowOfflineGrace: false), .expired)
        XCTAssertEqual(expired.use(at: now, allowOfflineGrace: true), .offlineGrace)

        futureClaims["iat"] = 2_000_301
        futureClaims["nbf"] = 2_000_301
        futureClaims["exp"] = 2_086_701
        XCTAssertThrowsError(
            try EntitlementVerifier().verify(token: try signer.sign(claims: futureClaims), context: context)
        )

        expiredClaims["exp"] = 1_999_699
        XCTAssertThrowsError(
            try EntitlementVerifier().verify(token: try signer.sign(claims: expiredClaims), context: context)
        )
    }

    func testFreeEntitlementNeverReceivesOfflineProGrace() throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        var claims = signer.validClaims(subject: fixtureSubject, now: now)
        claims["plan"] = "free"
        claims["features"] = EntitlementSnapshot.syntheticFree.features.map(\.rawValue).sorted()
        claims["maxVideoHeight"] = 720
        claims["subscriptionState"] = "none"
        claims["grantRevision"] = 0
        claims["iat"] = 1_900_000
        claims["nbf"] = 1_899_970
        claims["exp"] = 1_999_900

        let verified = try EntitlementVerifier().verify(
            token: try signer.sign(claims: claims),
            context: signer.context(subject: fixtureSubject, now: now)
        )

        XCTAssertEqual(verified.snapshot, .syntheticFree)
        XCTAssertEqual(verified.use(at: now, allowOfflineGrace: true), .expired)
    }

    func testPaidProNeverExtendsBeyondSignedAccessEndEvenDuringOfflineGrace() throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        var claims = signer.validClaims(subject: fixtureSubject, now: now)
        claims["schema"] = 2
        claims["paidThroughMs"] = 2_000_100_000
        claims["proAccessEndsAtMs"] = 2_259_300_000
        let verified = try EntitlementVerifier().verify(
            token: try signer.sign(claims: claims),
            context: signer.context(subject: fixtureSubject, now: now)
        )
        XCTAssertEqual(verified.snapshot.plan, .pro)
        XCTAssertEqual(verified.proAccessEndsAt, Date(timeIntervalSince1970: 2_259_300))
        XCTAssertEqual(verified.use(at: Date(timeIntervalSince1970: 2_259_300), allowOfflineGrace: true), .expired)

        claims["exp"] = 2_000_010
        claims["paidThroughMs"] = 1_740_811_000
        claims["proAccessEndsAtMs"] = 2_000_011_000
        let shortBound = try EntitlementVerifier().verify(
            token: try signer.sign(claims: claims),
            context: signer.context(subject: fixtureSubject, now: now)
        )
        XCTAssertEqual(shortBound.use(at: Date(timeIntervalSince1970: 2_000_010), allowOfflineGrace: true), .offlineGrace)
        XCTAssertEqual(shortBound.use(at: Date(timeIntervalSince1970: 2_000_011), allowOfflineGrace: true), .expired)
    }

    func testPaidProRejectsMissingInvalidOrOvershootingSignedBounds() throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        var valid = signer.validClaims(subject: fixtureSubject, now: now)
        valid["schema"] = 2
        valid["paidThroughMs"] = 2_086_400_000
        valid["proAccessEndsAtMs"] = 2_086_400_000
        for mutation in [
            { () -> [String: Any] in var value = valid; value.removeValue(forKey: "paidThroughMs"); return value }(),
            valid.merging(["proAccessEndsAtMs": 2_086_401_000]) { _, new in new },
            valid.merging(["exp": 2_086_402]) { _, new in new },
            valid.merging(["plan": "free"]) { _, new in new }
        ] {
            XCTAssertThrowsError(try EntitlementVerifier().verify(
                token: try signer.sign(claims: mutation),
                context: signer.context(subject: fixtureSubject, now: now)
            ))
        }
    }

    func testPaidProEnforcesMillisecondBoundaryBeforeRoundedJWTExpiry() throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        var claims = signer.validClaims(subject: fixtureSubject, now: now)
        claims["schema"] = 2
        claims["exp"] = 2_000_011
        claims["paidThroughMs"] = 2_000_010_250
        claims["proAccessEndsAtMs"] = 2_000_010_250

        let verified = try EntitlementVerifier().verify(
            token: try signer.sign(claims: claims),
            context: signer.context(subject: fixtureSubject, now: now)
        )
        XCTAssertEqual(verified.use(at: Date(timeIntervalSince1970: 2_000_010.249)), .current)
        XCTAssertEqual(verified.use(at: Date(timeIntervalSince1970: 2_000_010.250)), .expired)
        XCTAssertEqual(verified.use(at: Date(timeIntervalSince1970: 2_000_010.250), allowOfflineGrace: true), .expired)
    }

    func testSubscriptionFreeSchemaIsAcceptedWithoutPaidFieldsOrOfflineGrace() throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        var claims = signer.validClaims(subject: fixtureSubject, now: now)
        claims["schema"] = 2
        claims["plan"] = "free"
        claims["features"] = EntitlementSnapshot.syntheticFree.features.map(\.rawValue).sorted()
        claims["maxVideoHeight"] = 720
        claims["subscriptionState"] = "none"
        let verified = try EntitlementVerifier().verify(
            token: try signer.sign(claims: claims),
            context: signer.context(subject: fixtureSubject, now: now)
        )
        XCTAssertEqual(verified.snapshot.plan, .free)
        XCTAssertEqual(verified.snapshot.schemaVersion, 2)
        XCTAssertNil(verified.proAccessEndsAt)
        XCTAssertEqual(verified.use(at: verified.expiresAt, allowOfflineGrace: true), .expired)
    }
}
