import Foundation
import XCTest
@testable import YTDownloaderPro2

final class AccountPresentationTests: XCTestCase {
    private let verifiedAt = Date(timeIntervalSince1970: 1_790_208_000)

    func testDisabledModeHidesEveryAccountSurface() {
        for state in allStates {
            let sidebar = AccountSidebarPresentation.make(
                environment: .disabled,
                state: state,
                plan: .free,
                entitlementStatus: .free,
                locale: Locale(identifier: "zh-Hant")
            )
            let settings = AccountSettingsPresentation.make(
                environment: .disabled,
                state: state,
                plan: .free,
                entitlementStatus: .free,
                locale: Locale(identifier: "zh-Hant")
            )

            XCTAssertFalse(sidebar.isVisible)
            XCTAssertFalse(settings.isVisible)
        }
    }

    func testMockOffersSyntheticGoogleAndAppleWhileStagingOffersGoogleOnly() {
        let mock = AccountSettingsPresentation.make(
            environment: .mock,
            state: .signedOut,
            plan: .testPro,
            entitlementStatus: .free,
            locale: Locale(identifier: "en")
        )
        let staging = AccountSettingsPresentation.make(
            environment: .staging,
            state: .signedOut,
            plan: .free,
            entitlementStatus: .free,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(mock.availableProviders, [.google, .apple])
        XCTAssertEqual(staging.availableProviders, [.google])
        XCTAssertTrue(mock.developmentNotice.contains("Development Test Mode"))
        XCTAssertFalse(staging.developmentNotice.contains("Apple"))
    }

    func testSignedInPresentationUsesEffectivePlanInsteadOfIdentity() {
        let summary = accountSummary(provider: .google)
        let free = AccountSidebarPresentation.make(
            environment: .staging,
            state: .signedIn(summary),
            plan: .free,
            entitlementStatus: .verified(lastVerifiedAt: verifiedAt),
            locale: Locale(identifier: "en")
        )
        let pro = AccountSidebarPresentation.make(
            environment: .staging,
            state: .signedIn(summary),
            plan: .pro,
            entitlementStatus: .verified(lastVerifiedAt: verifiedAt),
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(free.subtitle, "Free · Google")
        XCTAssertEqual(pro.subtitle, "Pro · Google")
        XCTAssertEqual(pro.title, "Test User")
    }

    func testSignedInSettingsExposeOnlyMaskedEmailAndSanitizedEntitlementStatus() {
        let summary = accountSummary(provider: .google)
        let value = AccountSettingsPresentation.make(
            environment: .staging,
            state: .signedIn(summary),
            plan: .pro,
            entitlementStatus: .verified(lastVerifiedAt: verifiedAt),
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(value.plan, .pro)
        XCTAssertEqual(value.maskedEmail, "t•••@example.com")
        XCTAssertTrue(value.allowsEntitlementRefresh)
        XCTAssertTrue(value.entitlementDetail?.contains("Verified") == true)
        XCTAssertFalse(value.entitlementDetail?.contains("eyJ") == true)
        XCTAssertFalse(value.entitlementDetail?.contains("supabase") == true)
    }

    func testEveryEntitlementStatusHasBoundedLocalizedCopy() {
        let statuses: [EntitlementStatus] = [
            .free,
            .refreshing,
            .verified(lastVerifiedAt: verifiedAt),
            .offlineGrace(expiresAt: verifiedAt),
            .unavailable,
            .unavailableUsingCache,
            .rejected,
            .rejectedUsingCache,
            .requiresReauthentication
        ]

        for localeID in L10n.supportedLocaleIdentifiers {
            for status in statuses {
                let value = EntitlementStatusPresentation.text(
                    for: status,
                    locale: Locale(identifier: localeID)
                )
                XCTAssertFalse(value.isEmpty, "\(localeID): \(status)")
                XCTAssertLessThanOrEqual(value.count, 160, "\(localeID): \(status)")
                XCTAssertFalse(value.localizedCaseInsensitiveContains("jwt"))
                XCTAssertFalse(value.localizedCaseInsensitiveContains("supabase"))
            }
        }
    }

    func testPlanNamesDistinguishRealProFromInternalTestProInEveryLocale() {
        for localeID in L10n.supportedLocaleIdentifiers {
            let locale = Locale(identifier: localeID)
            let free = PlanSettingsPresentation(plan: .free).planName(locale: locale)
            let pro = PlanSettingsPresentation(plan: .pro).planName(locale: locale)
            let testPro = PlanSettingsPresentation(plan: .testPro).planName(locale: locale)

            XCTAssertNotEqual(free, pro)
            XCTAssertNotEqual(pro, testPro)
            XCTAssertNotEqual(free, testPro)
        }
    }

    func testSettingsUsesLocalizedTypedErrorsAndOnlyRetriesCredentialRemovalForRemovalFailure() {
        let locale = Locale(identifier: "ja")
        let expected: [(AuthPresentationError, Bool)] = [
            (.providerUnavailable, false),
            (.invalidSession, false),
            (.expiredSession, false),
            (.credentialStorageUnavailable, false),
            (.credentialRemovalFailed, true),
            (.signInFailed, false)
        ]

        for (error, retriesCredentialRemoval) in expected {
            let value = AccountSettingsPresentation.make(
                environment: .staging,
                state: .failed(error),
                plan: .free,
                entitlementStatus: .free,
                locale: locale
            )
            guard case let .failure(message, retries) = value.content else {
                return XCTFail("Expected failure presentation")
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertEqual(retries, retriesCredentialRemoval)
        }
    }

    private var allStates: [AccountSessionState] {
        [
            .disabled,
            .signedOut,
            .signingIn(.google),
            .restoring,
            .signedIn(accountSummary(provider: .google)),
            .requiresReauthentication(.google),
            .failed(.signInFailed),
            .signingOut
        ]
    }

    private func accountSummary(provider: AuthenticationProviderKind) -> AccountSummary {
        AccountSummary(
            provider: provider,
            accountID: "test-account",
            displayName: "Test User",
            maskedEmail: "t•••@example.com",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }
}
