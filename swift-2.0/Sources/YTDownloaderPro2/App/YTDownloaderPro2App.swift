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
                .frame(minWidth: 760, minHeight: 540)
                .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
        }

        Settings {
            LocalizedSceneRoot {
                SettingsView()
            }
                .environmentObject(appLifecycle.store)
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
    private var terminationTask: Task<Void, Never>?

    override convenience init() {
        self.init(store: DownloadStore.live())
    }

    init(store: DownloadStore) {
        self.store = store
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
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
