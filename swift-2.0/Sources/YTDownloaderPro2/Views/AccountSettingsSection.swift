import SwiftUI

enum AccountSettingsFocusControl: Hashable {
    case google
    case apple
    case retry
    case signOut
}

struct AccountSettingsFocusInitiator: Equatable {
    let control: AccountSettingsFocusControl
    let provider: AuthenticationProviderKind?
}

enum AccountSettingsFocusPolicy {
    static func availableControls(
        in presentation: AccountSettingsPresentation
    ) -> [AccountSettingsFocusControl] {
        guard presentation.isVisible else { return [] }
        return switch presentation.content {
        case .signedOut:
            [.google, .apple]
        case .operation:
            []
        case .signedIn:
            [.signOut]
        case let .reauthentication(provider):
            provider == nil ? [.google, .apple] : [.retry]
        case let .failure(_, retriesCredentialRemoval):
            retriesCredentialRemoval ? [.retry] : [.google, .apple]
        }
    }

    static func destination(
        after presentation: AccountSettingsPresentation,
        initiatedBy initiator: AccountSettingsFocusInitiator
    ) -> AccountSettingsFocusControl? {
        let destination: AccountSettingsFocusControl? = switch presentation.content {
        case .signedOut:
            providerControl(for: initiator)
        case .operation:
            nil
        case .signedIn:
            .signOut
        case let .reauthentication(provider):
            provider == nil ? providerControl(for: initiator) : .retry
        case let .failure(_, retriesCredentialRemoval):
            retriesCredentialRemoval ? .retry : providerControl(for: initiator)
        }

        guard let destination,
              availableControls(in: presentation).contains(destination) else { return nil }
        return destination
    }

    static func retainsInitiator(after presentation: AccountSettingsPresentation) -> Bool {
        guard presentation.isVisible else { return false }
        if case .operation = presentation.content { return true }
        return false
    }

    private static func providerControl(
        for initiator: AccountSettingsFocusInitiator
    ) -> AccountSettingsFocusControl {
        switch initiator.provider {
        case .apple:
            .apple
        case .google:
            .google
        case nil:
            initiator.control == .apple ? .apple : .google
        }
    }
}

struct AccountSettingsSection: View {
    @EnvironmentObject private var accountSessionStore: AccountSessionStore
    @Environment(\.locale) private var locale

    @FocusState private var focusedControl: AccountSettingsFocusControl?
    @State private var operationFocusInitiator: AccountSettingsFocusInitiator?
    @State private var lastProvider: AuthenticationProviderKind?

    private var presentation: AccountSettingsPresentation {
        AccountSettingsPresentation.make(
            environment: accountSessionStore.environment,
            state: accountSessionStore.state,
            locale: locale
        )
    }

    var body: some View {
        Section(L10n.string(.accountSettingsTitle, locale: locale)) {
            Text(presentation.developmentNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            accountContent
        }
        .onChange(of: accountSessionStore.state) { state in
            restoreFocus(after: state)
        }
    }

    @ViewBuilder
    private var accountContent: some View {
        switch presentation.content {
        case .signedOut:
            planRow(.free)
            Text(L10n.string(.accountFreeNoSignIn, locale: locale))
                .foregroundStyle(.secondary)
            providerButtons(disabled: false)

        case let .operation(title):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(title)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)

            Text(L10n.string(.accountDownloadsUnaffected, locale: locale))
                .foregroundStyle(.secondary)

            providerButtons(disabled: true)

            if accountSessionStore.isAuthenticationCancellationAvailable {
                Button {
                    accountSessionStore.cancelAuthentication()
                } label: {
                    Label(L10n.string(.commonCancel, locale: locale), systemImage: "xmark.circle")
                }
                .accessibilityLabel(L10n.string(.commonCancel, locale: locale))
            }

        case let .signedIn(summary):
            Text(summary.displayName)
                .font(.headline)
            Label(
                L10n.string(summary.provider.localizationKey, locale: locale),
                systemImage: summary.provider.systemImage
            )
            planRow(summary.planPreview)
            Button {
                beginSignOut(returningTo: .signOut, provider: summary.provider)
            } label: {
                Label(L10n.string(.accountSignOut, locale: locale), systemImage: "rectangle.portrait.and.arrow.right")
            }
            .focused($focusedControl, equals: .signOut)
            .accessibilityLabel(L10n.string(.accountSignOut, locale: locale))
            Text(L10n.string(.accountSignOutPreservesData, locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case let .reauthentication(provider):
            Text(L10n.string(.accountReauthenticate, locale: locale))
                .font(.headline)
            Text(L10n.string(.accountFreeStillAvailable, locale: locale))
                .foregroundStyle(.secondary)
            if let provider {
                Button {
                    beginSignIn(with: provider, returningTo: .retry)
                } label: {
                    Label(L10n.string(.accountRetry, locale: locale), systemImage: "arrow.clockwise")
                }
                .focused($focusedControl, equals: .retry)
                .accessibilityLabel(L10n.string(.accountRetry, locale: locale))
            } else {
                providerButtons(disabled: false)
            }

        case let .failure(message, retriesCredentialRemoval):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string(.accountFreeStillAvailable, locale: locale))
                .foregroundStyle(.secondary)
            if retriesCredentialRemoval {
                Button {
                    beginCredentialRemovalRetry(returningTo: .retry)
                } label: {
                    Label(L10n.string(.accountRetry, locale: locale), systemImage: "arrow.clockwise")
                }
                .focused($focusedControl, equals: .retry)
                .accessibilityLabel(L10n.string(.accountRetry, locale: locale))
            } else {
                providerButtons(disabled: false)
            }
        }
    }

    @ViewBuilder
    private func providerButtons(disabled: Bool) -> some View {
        Button {
            beginSignIn(with: .google, returningTo: .google)
        } label: {
            Label(
                L10n.string(.accountSignInGoogle, locale: locale),
                systemImage: AuthenticationProviderKind.google.systemImage
            )
        }
        .disabled(disabled)
        .focused($focusedControl, equals: .google)
        .accessibilityLabel(L10n.string(.accountSignInGoogle, locale: locale))

        Button {
            beginSignIn(with: .apple, returningTo: .apple)
        } label: {
            Label(
                L10n.string(.accountSignInApple, locale: locale),
                systemImage: AuthenticationProviderKind.apple.systemImage
            )
        }
        .disabled(disabled)
        .focused($focusedControl, equals: .apple)
        .accessibilityLabel(L10n.string(.accountSignInApple, locale: locale))
    }

    private func planRow(_ plan: MockPlanPreview) -> some View {
        LabeledContent(L10n.string(.accountCurrentPlan, locale: locale)) {
            Text(L10n.string(plan.localizationKey, locale: locale))
        }
    }

    private func beginSignIn(
        with provider: AuthenticationProviderKind,
        returningTo control: AccountSettingsFocusControl
    ) {
        lastProvider = provider
        operationFocusInitiator = .init(control: control, provider: provider)
        Task { await accountSessionStore.signIn(with: provider) }
    }

    private func beginSignOut(
        returningTo control: AccountSettingsFocusControl,
        provider: AuthenticationProviderKind?
    ) {
        lastProvider = provider ?? lastProvider
        operationFocusInitiator = .init(control: control, provider: provider ?? lastProvider)
        Task { await accountSessionStore.signOut() }
    }

    private func beginCredentialRemovalRetry(returningTo control: AccountSettingsFocusControl) {
        operationFocusInitiator = .init(control: control, provider: lastProvider)
        Task { await accountSessionStore.retryCredentialRemoval() }
    }

    private func restoreFocus(after state: AccountSessionState) {
        guard let operationFocusInitiator else { return }
        let resultingPresentation = AccountSettingsPresentation.make(
            environment: accountSessionStore.environment,
            state: state,
            locale: locale
        )
        let destination = AccountSettingsFocusPolicy.destination(
            after: resultingPresentation,
            initiatedBy: operationFocusInitiator
        )
        if !AccountSettingsFocusPolicy.retainsInitiator(after: resultingPresentation) {
            self.operationFocusInitiator = nil
        }
        if let destination {
            focusedControl = destination
        }
    }
}
