import Foundation

struct AccountSidebarPresentation: Equatable {
    let isVisible: Bool
    let title: String
    let subtitle: String
    let systemImage: String
    let showsProgress: Bool

    static func make(
        environment: AuthEnvironment,
        state: AccountSessionState,
        plan: AppPlan,
        entitlementStatus: EntitlementStatus,
        locale: Locale
    ) -> Self {
        guard environment.supportsAuthentication else { return hidden }

        switch state {
        case .disabled:
            return hidden
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
            return .init(
                isVisible: true,
                title: summary.displayName,
                subtitle: "\(plan.localizedName(locale: locale)) · \(provider)",
                systemImage: summary.provider.systemImage,
                showsProgress: entitlementStatus == .refreshing
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

    private static let hidden = Self(
        isVisible: false,
        title: "",
        subtitle: "",
        systemImage: "person.crop.circle",
        showsProgress: false
    )
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
    let plan: AppPlan
    let entitlementDetail: String?
    let maskedEmail: String?
    let availableProviders: [AuthenticationProviderKind]
    let allowsEntitlementRefresh: Bool

    init(
        isVisible: Bool,
        developmentNotice: String,
        content: Content,
        plan: AppPlan = .free,
        entitlementDetail: String? = nil,
        maskedEmail: String? = nil,
        availableProviders: [AuthenticationProviderKind] = [.google, .apple],
        allowsEntitlementRefresh: Bool = false
    ) {
        self.isVisible = isVisible
        self.developmentNotice = developmentNotice
        self.content = content
        self.plan = plan
        self.entitlementDetail = entitlementDetail
        self.maskedEmail = maskedEmail
        self.availableProviders = availableProviders
        self.allowsEntitlementRefresh = allowsEntitlementRefresh
    }

    static func make(
        environment: AuthEnvironment,
        state: AccountSessionState,
        plan: AppPlan,
        entitlementStatus: EntitlementStatus,
        locale: Locale
    ) -> Self {
        guard environment.supportsAuthentication else {
            return .init(isVisible: false, developmentNotice: "", content: .signedOut)
        }

        let notice = L10n.string(
            environment == .mock ? .accountDevelopmentMode : .accountStagingMode,
            locale: locale
        )
        let providers: [AuthenticationProviderKind] = environment == .staging
            ? [.google]
            : [.google, .apple]
        let entitlementDetail = EntitlementStatusPresentation.text(
            for: entitlementStatus,
            locale: locale
        )

        switch state {
        case .disabled:
            return .init(isVisible: false, developmentNotice: "", content: .signedOut)
        case .signedOut:
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .signedOut,
                plan: .free,
                entitlementDetail: entitlementDetail,
                availableProviders: providers
            )
        case .signingIn:
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .operation(title: L10n.string(.accountSigningIn, locale: locale)),
                plan: plan,
                entitlementDetail: entitlementDetail,
                availableProviders: providers
            )
        case .restoring:
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .operation(title: L10n.string(.accountRestoring, locale: locale)),
                plan: plan,
                entitlementDetail: entitlementDetail,
                availableProviders: providers
            )
        case let .signedIn(summary):
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .signedIn(summary),
                plan: plan,
                entitlementDetail: entitlementDetail,
                maskedEmail: summary.maskedEmail,
                availableProviders: providers,
                allowsEntitlementRefresh: entitlementStatus != .refreshing
            )
        case let .requiresReauthentication(provider):
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .reauthentication(provider),
                plan: plan,
                entitlementDetail: entitlementDetail,
                availableProviders: providers
            )
        case let .failed(error):
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .failure(
                    message: L10n.string(error.localizationKey, locale: locale),
                    retriesCredentialRemoval: error == .credentialRemovalFailed
                ),
                plan: plan,
                entitlementDetail: entitlementDetail,
                availableProviders: providers
            )
        case .signingOut:
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .operation(title: L10n.string(.accountSignOut, locale: locale)),
                plan: plan,
                entitlementDetail: entitlementDetail,
                availableProviders: providers
            )
        }
    }
}

enum EntitlementStatusPresentation {
    static func text(for status: EntitlementStatus, locale: Locale) -> String {
        switch status {
        case .free:
            L10n.string(.accountEntitlementFree, locale: locale)
        case .refreshing:
            L10n.string(.accountEntitlementRefreshing, locale: locale)
        case let .verified(lastVerifiedAt):
            L10n.string(
                .accountEntitlementVerified,
                locale: locale,
                localizedDate(lastVerifiedAt, locale: locale)
            )
        case let .offlineGrace(expiresAt):
            L10n.string(
                .accountEntitlementOfflineGrace,
                locale: locale,
                localizedDate(expiresAt, locale: locale)
            )
        case .unavailable:
            L10n.string(.accountEntitlementUnavailable, locale: locale)
        case .unavailableUsingCache:
            L10n.string(.accountEntitlementUnavailableUsingCache, locale: locale)
        case .rejected:
            L10n.string(.accountEntitlementRejected, locale: locale)
        case .rejectedUsingCache:
            L10n.string(.accountEntitlementRejectedUsingCache, locale: locale)
        case .requiresReauthentication:
            L10n.string(.accountEntitlementRequiresReauthentication, locale: locale)
        }
    }

    private static func localizedDate(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension AppPlan {
    func localizedName(locale: Locale) -> String {
        let key: L10n.Key = switch self {
        case .free: .accountFreePlan
        case .pro: .accountProPlan
        case .testPro: .accountTestProPlan
        }
        return L10n.string(key, locale: locale)
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
