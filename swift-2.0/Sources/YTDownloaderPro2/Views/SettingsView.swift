import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        Form {
            Section("Downloads") {
                Stepper(
                    "Concurrent downloads: \(store.settings.maximumConcurrentDownloads)",
                    value: maximumDownloads,
                    in: AppSettings.supportedConcurrentDownloads
                )
            }

            Section("Default options") {
                DownloadOptionsEditor(options: defaultOptions, videoChoices: [], audioChoices: [])
            }

            Section("Preferences") {
                Picker("Language", selection: languageOverride) {
                    Text("System default").tag(String?.none)
                    Text("Traditional Chinese").tag(Optional("zh-Hant"))
                    Text("English").tag(Optional("en"))
                    Text("Japanese").tag(Optional("ja"))
                }
                Toggle("Automatically check for updates", isOn: automaticUpdateChecks)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 640, minHeight: 580)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
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

    private func updateSettings(_ update: (inout AppSettings) -> Void) {
        var settings = store.settings
        update(&settings)
        store.settings = settings
    }
}
