import AppKit
import SwiftUI

@main
struct YTDownloaderPro2App: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var appLifecycle

    var body: some Scene {
        WindowGroup {
            LocalizedSceneRoot {
                DownloadCenterView()
            }
                .environmentObject(appLifecycle.store)
                .environmentObject(appLifecycle.accountSessionStore)
                .environmentObject(appLifecycle.planController)
                .frame(minWidth: 760, minHeight: 540)
                .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
        }

        Settings {
            LocalizedSceneRoot {
                SettingsView()
            }
                .environmentObject(appLifecycle.store)
                .environmentObject(appLifecycle.accountSessionStore)
                .environmentObject(appLifecycle.planController)
                .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
        }
    }
}

struct LocalizedSceneRoot<Content: View>: View {
    @EnvironmentObject private var store: DownloadStore

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.locale, store.settings.locale)
    }
}

struct LocalizedSheetRoot<Content: View>: View {
    let locale: Locale
    private let content: Content

    init(locale: Locale, @ViewBuilder content: () -> Content) {
        self.locale = locale
        self.content = content()
    }

    var body: some View {
        content.environment(\.locale, locale)
    }
}

enum TerminationSafetyPolicy {
    static func shouldTerminate(after result: Result<Void, Error>) -> Bool {
        switch result {
        case .success:
            true
        case .failure:
            false
        }
    }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    let store: DownloadStore
    let accountSessionStore: AccountSessionStore
    let planController: PlanController
    private var terminationTask: Task<Void, Never>?

    override convenience init() {
        let featurePolicyResolution = FeaturePolicyEnvironmentResolution.resolve()
        let planController = PlanController.live()
        self.init(
            store: DownloadStore.live(featurePolicyResolution: featurePolicyResolution),
            accountSessionStore: .live(),
            planController: planController
        )
    }

    init(
        store: DownloadStore,
        accountSessionStore: AccountSessionStore? = nil,
        planController: PlanController? = nil
    ) {
        self.store = store
        self.accountSessionStore = accountSessionStore ?? AccountSessionStore(
            environment: .disabled,
            vault: InMemoryCredentialVault(),
            providers: .init([])
        )
        self.planController = planController ?? PlanController(
            buildChannel: .publicRelease,
            provider: PublicFreePlanProvider()
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        startAutomaticUpdateCheck()
        startAuthenticationRestoration()
    }

    func startAutomaticUpdateCheck() {
        Task { @MainActor [store] in
            await store.checkForUpdates(manual: false)
        }
    }

    func startAuthenticationRestoration() {
        Task { @MainActor [accountSessionStore] in
            await accountSessionStore.restoreSession()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { @MainActor [weak self, store] in
            let result: Result<Void, Error>
            do {
                try await store.prepareToQuit()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            sender.reply(toApplicationShouldTerminate: TerminationSafetyPolicy.shouldTerminate(after: result))
            self?.terminationTask = nil
        }
        return .terminateLater
    }
}
