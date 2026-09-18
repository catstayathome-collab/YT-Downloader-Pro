import Foundation
import XCTest
@testable import YTDownloaderPro2

final class AccountPresentationTests: XCTestCase {
    func testDisabledModeHidesEveryAccountSurface() {
        let sidebar = AccountSidebarPresentation.make(
            environment: .disabled,
            state: .disabled,
            locale: Locale(identifier: "zh-Hant")
        )
        let settings = AccountSettingsPresentation.make(
            environment: .disabled,
            state: .disabled,
            locale: Locale(identifier: "zh-Hant")
        )

        XCTAssertEqual(sidebar, .init(
            isVisible: false,
            title: "",
            subtitle: "",
            systemImage: "person.crop.circle",
            showsProgress: false
        ))
        XCTAssertEqual(settings, .init(isVisible: false, developmentNotice: "", content: .signedOut))
    }

    func testDisabledEnvironmentHidesEveryAccountSurfaceForEverySessionState() {
        let summary = accountSummary(provider: .google, planPreview: .pro)
        let states: [AccountSessionState] = [
            .disabled,
            .signedOut,
            .signingIn(.apple),
            .restoring,
            .signedIn(summary),
            .requiresReauthentication(.google),
            .failed(.credentialRemovalFailed),
            .signingOut
        ]
        let hiddenSidebar = AccountSidebarPresentation(
            isVisible: false,
            title: "",
            subtitle: "",
            systemImage: "person.crop.circle",
            showsProgress: false
        )
        let hiddenSettings = AccountSettingsPresentation(
            isVisible: false,
            developmentNotice: "",
            content: .signedOut
        )

        for state in states {
            XCTAssertEqual(
                AccountSidebarPresentation.make(
                    environment: .disabled,
                    state: state,
                    locale: Locale(identifier: "en")
                ),
                hiddenSidebar,
                "Sidebar exposed disabled environment for \(state)"
            )
            XCTAssertEqual(
                AccountSettingsPresentation.make(
                    environment: .disabled,
                    state: state,
                    locale: Locale(identifier: "en")
                ),
                hiddenSettings,
                "Settings exposed disabled environment for \(state)"
            )
        }
    }

    func testSignedInSidebarUsesSyntheticNameAndTestPlan() {
        let summary = AccountSummary.fixture(provider: .google)
        let value = AccountSidebarPresentation.make(
            environment: .mock,
            state: .signedIn(summary),
            locale: Locale(identifier: "zh-Hant")
        )

        XCTAssertEqual(value.title, summary.displayName)
        XCTAssertEqual(value.subtitle, "測試 Pro · Google")
        XCTAssertEqual(value.systemImage, "person.crop.circle")
        XCTAssertFalse(value.showsProgress)
    }

    func testSignedInSidebarMapsEveryProviderAndPlanCombination() {
        let expected: [(AuthenticationProviderKind, MockPlanPreview, String, String)] = [
            (.google, .free, "Free · Google", "person.crop.circle"),
            (.google, .pro, "Test Pro · Google", "person.crop.circle"),
            (.apple, .free, "Free · Apple", "apple.logo"),
            (.apple, .pro, "Test Pro · Apple", "apple.logo")
        ]

        for (provider, planPreview, subtitle, systemImage) in expected {
            let summary = accountSummary(provider: provider, planPreview: planPreview)
            let value = AccountSidebarPresentation.make(
                environment: .mock,
                state: .signedIn(summary),
                locale: Locale(identifier: "en")
            )

            XCTAssertEqual(value.title, "Test User")
            XCTAssertEqual(value.subtitle, subtitle)
            XCTAssertEqual(value.systemImage, systemImage)
            XCTAssertFalse(value.showsProgress)
        }
    }

    func testProviderPresentationMappingsAreExhaustive() {
        let expected: [(AuthenticationProviderKind, String, String)] = [
            (.google, "Google", "person.crop.circle"),
            (.apple, "Apple", "apple.logo")
        ]

        for (provider, label, systemImage) in expected {
            XCTAssertEqual(
                L10n.string(provider.localizationKey, locale: Locale(identifier: "en")),
                label
            )
            XCTAssertEqual(provider.systemImage, systemImage)
        }
    }

    func testPlanPresentationMappingsAreExhaustive() {
        let expected: [(MockPlanPreview, String)] = [
            (.free, "Free"),
            (.pro, "Test Pro")
        ]

        for (planPreview, label) in expected {
            XCTAssertEqual(
                L10n.string(planPreview.localizationKey, locale: Locale(identifier: "en")),
                label
            )
        }
    }

    func testSidebarExhaustivelyMapsEveryNonSignedInState() {
        let locale = Locale(identifier: "en")
        let expected: [(AccountSessionState, AccountSidebarPresentation)] = [
            (.signedOut, .init(
                isVisible: true,
                title: "Sign in or view plans",
                subtitle: "Free; no sign-in required",
                systemImage: "person.crop.circle",
                showsProgress: false
            )),
            (.signingIn(.apple), .init(
                isVisible: true,
                title: "Signing in",
                subtitle: "Downloads are unaffected",
                systemImage: "apple.logo",
                showsProgress: true
            )),
            (.restoring, .init(
                isVisible: true,
                title: "Restoring account",
                subtitle: "Downloads are unaffected",
                systemImage: "person.crop.circle",
                showsProgress: true
            )),
            (.requiresReauthentication(.apple), .init(
                isVisible: true,
                title: "Sign in again",
                subtitle: "Free downloads remain available",
                systemImage: "person.crop.circle.badge.exclamationmark",
                showsProgress: false
            )),
            (.failed(.invalidSession), .init(
                isVisible: true,
                title: "Account unavailable",
                subtitle: "Open Settings to retry",
                systemImage: "exclamationmark.circle",
                showsProgress: false
            )),
            (.signingOut, .init(
                isVisible: true,
                title: "Sign Out",
                subtitle: "Downloads are unaffected",
                systemImage: "person.crop.circle",
                showsProgress: true
            ))
        ]

        for (state, value) in expected {
            XCTAssertEqual(AccountSidebarPresentation.make(environment: .mock, state: state, locale: locale), value)
        }
    }

    func testSettingsExhaustivelyMapsEverySessionState() {
        let locale = Locale(identifier: "en")
        let summary = AccountSummary.fixture(provider: .google)
        let notice = "Development Test Mode: no connection to Google, Apple, or production services."
        let expected: [(AccountSessionState, AccountSettingsPresentation)] = [
            (.disabled, .init(isVisible: false, developmentNotice: "", content: .signedOut)),
            (.signedOut, .init(isVisible: true, developmentNotice: notice, content: .signedOut)),
            (.signingIn(.google), .init(isVisible: true, developmentNotice: notice, content: .operation(title: "Signing in"))),
            (.restoring, .init(isVisible: true, developmentNotice: notice, content: .operation(title: "Restoring account"))),
            (.signedIn(summary), .init(isVisible: true, developmentNotice: notice, content: .signedIn(summary))),
            (.requiresReauthentication(nil), .init(isVisible: true, developmentNotice: notice, content: .reauthentication(nil))),
            (.signingOut, .init(isVisible: true, developmentNotice: notice, content: .operation(title: "Sign Out")))
        ]

        for (state, value) in expected {
            XCTAssertEqual(AccountSettingsPresentation.make(environment: .mock, state: state, locale: locale), value)
        }
    }

    func testSettingsUsesLocalizedTypedErrorsAndOnlyRetriesSignOutForRemovalFailure() {
        let locale = Locale(identifier: "ja")
        let expected: [(AuthPresentationError, String, Bool)] = [
            (.providerUnavailable, "このサインイン方法は利用できません。", false),
            (.invalidSession, "保存されたアカウントセッションは無効です。もう一度サインインしてください。", false),
            (.expiredSession, "アカウントセッションの有効期限が切れました。もう一度サインインしてください。", false),
            (.credentialStorageUnavailable, "この Mac にアカウントセッションを安全に保存できませんでした。", false),
            (.credentialRemovalFailed, "保存されたアカウントセッションを削除できませんでした。もう一度サインアウトしてください。", true),
            (.signInFailed, "サインインを完了できませんでした。もう一度お試しください。", false)
        ]

        for (error, message, retriesSignOut) in expected {
            let value = AccountSettingsPresentation.make(environment: .mock, state: .failed(error), locale: locale)
            XCTAssertEqual(value.content, .failure(message: message, retriesSignOut: retriesSignOut))
        }
    }

    func testSettingsPreservesEveryReauthenticationProviderAssociation() {
        let expected: [(AuthenticationProviderKind?, AccountSettingsPresentation.Content)] = [
            (nil, .reauthentication(nil)),
            (.google, .reauthentication(.google)),
            (.apple, .reauthentication(.apple))
        ]

        for (provider, content) in expected {
            let value = AccountSettingsPresentation.make(
                environment: .mock,
                state: .requiresReauthentication(provider),
                locale: Locale(identifier: "en")
            )

            XCTAssertEqual(value.content, content)
        }
    }

    private func accountSummary(
        provider: AuthenticationProviderKind,
        planPreview: MockPlanPreview
    ) -> AccountSummary {
        AccountSummary(
            provider: provider,
            accountID: "test-account",
            displayName: "Test User",
            planPreview: planPreview,
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }
}
