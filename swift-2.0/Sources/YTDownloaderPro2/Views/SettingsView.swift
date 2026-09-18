import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var accountSessionStore: AccountSessionStore
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            let accountPresentation = AccountSettingsPresentation.make(
                environment: accountSessionStore.environment,
                state: accountSessionStore.state,
                locale: locale
            )
            if accountPresentation.isVisible {
                AccountSettingsSection()
            }

            Section(L10n.string(.settingsDownloads, locale: locale)) {
                Stepper(
                    L10n.string(
                        .settingsConcurrentDownloads,
                        locale: locale,
                        Int64(store.settings.maximumConcurrentDownloads)
                    ),
                    value: maximumDownloads,
                    in: AppSettings.supportedConcurrentDownloads
                )
            }

            Section(L10n.string(.settingsDefaultOptions, locale: locale)) {
                DownloadOptionsEditor(options: defaultOptions, videoChoices: [], audioChoices: [])
            }

            Section(L10n.string(.settingsPreferences, locale: locale)) {
                Picker(L10n.string(.settingsLanguage, locale: locale), selection: languageOverride) {
                    Text(L10n.string(.settingsLanguageSystem, locale: locale)).tag(String?.none)
                    Text(L10n.string(.settingsLanguageTraditionalChinese, locale: locale)).tag(Optional("zh-Hant"))
                    Text(L10n.string(.settingsLanguageEnglish, locale: locale)).tag(Optional("en"))
                    Text(L10n.string(.settingsLanguageJapanese, locale: locale)).tag(Optional("ja"))
                }
            }

            Section(L10n.string(.settingsUpdates, locale: locale)) {
                Toggle(L10n.string(.settingsAutomaticUpdates, locale: locale), isOn: automaticUpdateChecks)
                Button {
                    Task { await store.checkForUpdates(manual: true) }
                } label: {
                    Label(
                        store.isCheckingForUpdatesManually
                            ? UpdateControlPresentation.checkingTitle(locale: locale)
                            : UpdateControlPresentation.checkTitle(locale: locale),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(store.isCheckingForUpdatesManually)
                .accessibilityLabel(UpdateControlPresentation.accessibilityLabel(locale: locale))
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 640, minHeight: 580)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
        .alert(item: manualUpdateNotice) { notice in
            UpdateAlertFactory.make(notice: notice, locale: locale)
        }
    }

    private var maximumDownloads: Binding<Int> {
        Binding(
            get: { store.settings.maximumConcurrentDownloads },
            set: { value in updateSettings { $0.maximumConcurrentDownloads = value } }
        )
    }

    private var defaultOptions: Binding<DownloadOptions> {
        Binding(
            get: { store.settings.defaultOptions },
            set: { value in updateSettings { $0.defaultOptions = value } }
        )
    }

    private var languageOverride: Binding<String?> {
        Binding(
            get: { store.settings.languageOverride },
            set: { value in updateSettings { $0.languageOverride = value } }
        )
    }

    private var automaticUpdateChecks: Binding<Bool> {
        Binding(
            get: { store.settings.automaticallyCheckForUpdates },
            set: { value in updateSettings { $0.automaticallyCheckForUpdates = value } }
        )
    }

    private var manualUpdateNotice: Binding<UpdateNotice?> {
        Binding(
            get: { store.manualUpdateNotice },
            set: { notice in
                guard notice == nil, let id = store.manualUpdateNotice?.id else { return }
                store.dismissManualUpdateNotice(id: id)
            }
        )
    }

    private func updateSettings(_ update: (inout AppSettings) -> Void) {
        var settings = store.settings
        update(&settings)
        store.settings = settings
    }
}
