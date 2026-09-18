import Foundation

struct AccountSidebarPresentation: Equatable {
    let isVisible: Bool
    let title: String
    let subtitle: String
    let systemImage: String
    let showsProgress: Bool

    static func make(environment: AuthEnvironment, state: AccountSessionState, locale: Locale) -> Self {
        guard environment == .mock else {
            return .init(isVisible: false, title: "", subtitle: "", systemImage: "person.crop.circle", showsProgress: false)
        }

        switch state {
        case .disabled:
            return .init(isVisible: false, title: "", subtitle: "", systemImage: "person.crop.circle", showsProgress: false)
        case .signedOut:
            return .init(
                isVisible: true,
                title: L10n.string(.accountSignInOrViewPlans, locale: locale),
                subtitle: L10n.string(.accountFreeNoSignIn, locale: locale),
                systemImage: "person.crop.circle",
                showsProgress: false
            )
        case let .signingIn(provider):
            return .init(
                isVisible: true,
                title: L10n.string(.accountSigningIn, locale: locale),
                subtitle: L10n.string(.accountDownloadsUnaffected, locale: locale),
                systemImage: provider.systemImage,
                showsProgress: true
            )
        case .restoring:
            return .init(
                isVisible: true,
                title: L10n.string(.accountRestoring, locale: locale),
                subtitle: L10n.string(.accountDownloadsUnaffected, locale: locale),
                systemImage: "person.crop.circle",
                showsProgress: true
            )
        case let .signedIn(summary):
            let provider = L10n.string(summary.provider.localizationKey, locale: locale)
            let plan = L10n.string(summary.planPreview.localizationKey, locale: locale)
            return .init(
                isVisible: true,
                title: summary.displayName,
                subtitle: "\(plan) · \(provider)",
                systemImage: summary.provider.systemImage,
                showsProgress: false
            )
        case .requiresReauthentication:
            return .init(
                isVisible: true,
                title: L10n.string(.accountReauthenticate, locale: locale),
                subtitle: L10n.string(.accountFreeStillAvailable, locale: locale),
                systemImage: "person.crop.circle.badge.exclamationmark",
                showsProgress: false
            )
        case .failed:
            return .init(
                isVisible: true,
                title: L10n.string(.accountUnavailable, locale: locale),
                subtitle: L10n.string(.accountOpenSettingsRetry, locale: locale),
                systemImage: "exclamationmark.circle",
                showsProgress: false
            )
        case .signingOut:
            return .init(
                isVisible: true,
                title: L10n.string(.accountSignOut, locale: locale),
                subtitle: L10n.string(.accountDownloadsUnaffected, locale: locale),
                systemImage: "person.crop.circle",
                showsProgress: true
            )
        }
    }
}

struct AccountSettingsPresentation: Equatable {
    enum Content: Equatable {
        case signedOut
        case operation(title: String)
        case signedIn(AccountSummary)
        case reauthentication(AuthenticationProviderKind?)
        case failure(message: String, retriesCredentialRemoval: Bool)
    }

    let isVisible: Bool
    let developmentNotice: String
    let content: Content

    static func make(environment: AuthEnvironment, state: AccountSessionState, locale: Locale) -> Self {
        guard environment == .mock else {
            return .init(isVisible: false, developmentNotice: "", content: .signedOut)
        }

        let notice = L10n.string(.accountDevelopmentMode, locale: locale)
        switch state {
        case .disabled:
            return .init(isVisible: false, developmentNotice: "", content: .signedOut)
        case .signedOut:
            return .init(isVisible: true, developmentNotice: notice, content: .signedOut)
        case .signingIn:
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .operation(title: L10n.string(.accountSigningIn, locale: locale))
            )
        case .restoring:
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .operation(title: L10n.string(.accountRestoring, locale: locale))
            )
        case let .signedIn(summary):
            return .init(isVisible: true, developmentNotice: notice, content: .signedIn(summary))
        case let .requiresReauthentication(provider):
            return .init(isVisible: true, developmentNotice: notice, content: .reauthentication(provider))
        case let .failed(error):
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .failure(
                    message: L10n.string(error.localizationKey, locale: locale),
                    retriesCredentialRemoval: error == .credentialRemovalFailed
                )
            )
        case .signingOut:
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .operation(title: L10n.string(.accountSignOut, locale: locale))
            )
        }
    }
}

extension AuthenticationProviderKind {
    var localizationKey: L10n.Key {
        self == .google ? .accountProviderGoogle : .accountProviderApple
    }

    var systemImage: String {
        self == .apple ? "apple.logo" : "person.crop.circle"
    }
}

extension MockPlanPreview {
    var localizationKey: L10n.Key {
        self == .pro ? .accountTestProPlan : .accountFreePlan
    }
}

extension AuthPresentationError {
    var localizationKey: L10n.Key {
        switch self {
        case .providerUnavailable: .accountErrorProviderUnavailable
        case .invalidSession: .accountErrorInvalidSession
        case .expiredSession: .accountErrorExpiredSession
        case .credentialStorageUnavailable: .accountErrorStorageUnavailable
        case .credentialRemovalFailed: .accountErrorRemovalFailed
        case .signInFailed: .accountErrorSignInFailed
        }
    }
}
