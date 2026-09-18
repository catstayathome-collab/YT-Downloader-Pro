import SwiftUI

struct AccountSettingsSection: View {
    @EnvironmentObject private var accountSessionStore: AccountSessionStore
    @Environment(\.locale) private var locale

    @FocusState private var focusedControl: FocusedControl?
    @State private var operationReturnFocus: FocusedControl?

    private enum FocusedControl: Hashable {
        case google
        case apple
        case retry
        case signOut
    }

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
                beginSignOut(returningTo: .signOut)
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

        case let .failure(message, retriesSignOut):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string(.accountFreeStillAvailable, locale: locale))
                .foregroundStyle(.secondary)
            if retriesSignOut {
                Button {
                    beginSignOut(returningTo: .retry)
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

    private func beginSignIn(with provider: AuthenticationProviderKind, returningTo control: FocusedControl) {
        operationReturnFocus = control
        Task { await accountSessionStore.signIn(with: provider) }
    }

    private func beginSignOut(returningTo control: FocusedControl) {
        operationReturnFocus = control
        Task { await accountSessionStore.signOut() }
    }

    private func restoreFocus(after state: AccountSessionState) {
        guard !isOperation(state), let operationReturnFocus else { return }
        switch state {
        case .signedIn:
            focusedControl = .signOut
        case .signedOut:
            focusedControl = operationReturnFocus == .apple ? .apple : .google
        case .requiresReauthentication:
            focusedControl = .retry
        case let .failed(error):
            focusedControl = error == .credentialRemovalFailed ? .retry : operationReturnFocus
        case .disabled, .signingIn, .restoring, .signingOut:
            break
        }
        self.operationReturnFocus = nil
    }

    private func isOperation(_ state: AccountSessionState) -> Bool {
        switch state {
        case .signingIn, .restoring, .signingOut:
            true
        case .disabled, .signedOut, .signedIn, .requiresReauthentication, .failed:
            false
        }
    }
}
