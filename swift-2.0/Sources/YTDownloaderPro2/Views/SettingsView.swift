import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var accountSessionStore: AccountSessionStore
    @Environment(\.locale) private var locale
    @State private var showsSupportReport = false
    @State private var showsLocalExport = false
    @State private var showsLocalDataManagement = false

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

            Section("Support") {
                Button {
                    showsSupportReport = true
                } label: {
                    Label("Create Local Support Report", systemImage: "lifepreserver")
                }
                .accessibilityLabel("Create and review a local support report")
            }

            Section("Data") {
                Button {
                    showsLocalExport = true
                } label: {
                    Label("Export Local App Data", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Review and export sanitized local app data")

                Button {
                    showsLocalDataManagement = true
                } label: {
                    Label("Manage Local Data", systemImage: "externaldrive.badge.minus")
                }
                .accessibilityLabel("Review local data clearing and media deletion actions")
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
        .sheet(isPresented: $showsSupportReport) {
            SupportReportView(environment: supportEnvironment)
        }
        .sheet(isPresented: $showsLocalExport) {
            LocalDataExportView(appVersion: appVersion, releaseChannel: releaseChannel)
                .environmentObject(store)
        }
        .sheet(isPresented: $showsLocalDataManagement) {
            LocalDataManagementView()
                .environmentObject(store)
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
    }

    private var releaseChannel: String {
        Bundle.main.object(forInfoDictionaryKey: "YTDPReleaseChannel") as? String
            ?? "local"
    }

    private var supportEnvironment: SupportReportDraft.Environment {
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        return SupportReportDraft.Environment(
            appVersion: appVersion,
            releaseChannel: releaseChannel,
            macOSVersion: "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)",
            architecture: Self.architecture,
            localeIdentifier: locale.identifier
        )
    }

    private static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }
}
