import OSLog

enum AuthenticationDiagnosticEvent: String, Codable, CaseIterable, Sendable {
    case signInStarted = "auth.sign-in.started"
    case signInCancelled = "auth.sign-in.cancelled"
    case signInFailed = "auth.sign-in.failed"
    case sessionRestored = "auth.session.restored"
    case sessionExpired = "auth.session.expired"
    case storageUnavailable = "auth.storage.unavailable"
    case signOutCompleted = "auth.sign-out.completed"
}

protocol AuthenticationDiagnosticsRecording: Sendable {
    func record(_ event: AuthenticationDiagnosticEvent) async
}

struct SystemAuthenticationDiagnosticsRecorder: AuthenticationDiagnosticsRecording {
    private let logger = Logger(
        subsystem: "com.catstayathome.YTDownloaderPro",
        category: "Authentication"
    )

    func record(_ event: AuthenticationDiagnosticEvent) async {
        logger.info("\(event.rawValue, privacy: .public)")
    }
}
