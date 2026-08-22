import AppKit
import Foundation
import SwiftUI

enum UpdateCheckOrigin: Equatable, Sendable {
    case automatic
    case manual
}

struct UpdateNotice: Equatable, Identifiable, Sendable {
    let id: UInt64
    let result: UpdateResult
    let origin: UpdateCheckOrigin
}

struct UpdateAlertPresentation: Equatable {
    let title: String
    let message: String
    let dismissTitle: String
    let openReleaseTitle: String?
    let releaseURL: URL?

    init?(notice: UpdateNotice, locale: Locale) {
        if notice.origin == .automatic {
            switch notice.result {
            case .available, .unsupportedOS:
                break
            case .upToDate, .failed:
                return nil
            }
        }

        dismissTitle = L10n.string(.updateDismiss, locale: locale)
        switch notice.result {
        case let .available(manifest):
            title = L10n.string(.updateAvailableTitle, locale: locale)
            message = L10n.string(
                .updateAvailableMessage,
                locale: locale,
                manifest.latestVersion,
                manifest.releaseNotes
            )
            openReleaseTitle = L10n.string(.updateOpenRelease, locale: locale)
            releaseURL = manifest.releaseURL
        case let .unsupportedOS(manifest):
            title = L10n.string(.updateUnsupportedTitle, locale: locale)
            message = L10n.string(
                .updateUnsupportedMessage,
                locale: locale,
                manifest.latestVersion,
                manifest.minimumMacOS
            )
            openReleaseTitle = nil
            releaseURL = nil
        case .upToDate:
            title = L10n.string(.updateUpToDateTitle, locale: locale)
            message = L10n.string(.updateUpToDateMessage, locale: locale)
            openReleaseTitle = nil
            releaseURL = nil
        case .failed(.silentTransient):
            return nil
        case .failed:
            title = L10n.string(.updateFailedTitle, locale: locale)
            message = L10n.string(.updateFailedMessage, locale: locale)
            openReleaseTitle = nil
            releaseURL = nil
        }
    }
}

enum UpdateControlPresentation {
    static func checkTitle(locale: Locale) -> String {
        L10n.string(.updateCheck, locale: locale)
    }

    static func checkingTitle(locale: Locale) -> String {
        L10n.string(.updateChecking, locale: locale)
    }

    static func accessibilityLabel(locale: Locale) -> String {
        L10n.string(.updateCheckAccessibility, locale: locale)
    }
}

enum UpdateReleaseCommand {
    @MainActor
    static func open(_ url: URL) -> Bool {
        open(url, opener: NSWorkspace.shared.open)
    }

    @MainActor
    static func open(_ url: URL, opener: (URL) -> Bool) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return opener(url)
    }
}

enum UpdateAlertFactory {
    @MainActor
    static func make(notice: UpdateNotice, locale: Locale) -> Alert {
        guard let presentation = UpdateAlertPresentation(notice: notice, locale: locale) else {
            return Alert(title: Text(""))
        }
        if let releaseURL = presentation.releaseURL,
           let openReleaseTitle = presentation.openReleaseTitle {
            return Alert(
                title: Text(presentation.title),
                message: Text(presentation.message),
                primaryButton: .default(Text(openReleaseTitle)) {
                    _ = UpdateReleaseCommand.open(releaseURL)
                },
                secondaryButton: .cancel(Text(presentation.dismissTitle))
            )
        }
        return Alert(
            title: Text(presentation.title),
            message: Text(presentation.message),
            dismissButton: .default(Text(presentation.dismissTitle))
        )
    }
}
