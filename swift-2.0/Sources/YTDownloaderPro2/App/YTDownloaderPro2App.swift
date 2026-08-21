import AppKit
import SwiftUI

@main
struct YTDownloaderPro2App: App {
    @NSApplicationDelegateAdaptor(QuitPreparationDelegate.self) private var quitPreparationDelegate
    @StateObject private var store = DownloadStore.live()

    var body: some Scene {
        WindowGroup {
            Text("YT Downloader Pro")
                .environmentObject(store)
                .task {
                    quitPreparationDelegate.store = store
                }
        }
    }
}

@MainActor
private final class QuitPreparationDelegate: NSObject, NSApplicationDelegate {
    weak var store: DownloadStore?
    private var isPreparing = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !isPreparing else { return .terminateLater }
        isPreparing = true

        Task { @MainActor [weak self] in
            await store.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
            self?.isPreparing = false
        }
        return .terminateLater
    }
}
