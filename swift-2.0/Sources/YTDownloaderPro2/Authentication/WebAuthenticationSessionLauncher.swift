#if canImport(AuthenticationServices)
import AppKit
import AuthenticationServices
import Foundation

enum WebAuthenticationSessionFailure: Error, Equatable, Sendable {
    case cancelled
    case invalidResponse
    case unavailable
}

enum WebAuthenticationSessionCallbackBridge {
    nonisolated static func make(
        completion: @escaping @MainActor @Sendable (
            Result<URL, WebAuthenticationSessionFailure>
        ) -> Void
    ) -> @Sendable (URL?, Error?) -> Void {
        { url, error in
            let result: Result<URL, WebAuthenticationSessionFailure>
            if let webError = error as? ASWebAuthenticationSessionError,
               webError.code == .canceledLogin {
                result = .failure(.cancelled)
            } else if error != nil {
                result = .failure(.unavailable)
            } else if let url {
                result = .success(url)
            } else {
                result = .failure(.invalidResponse)
            }

            Task { @MainActor in
                completion(result)
            }
        }
    }
}

@MainActor
final class WebAuthenticationSessionLauncher: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackURLScheme: String?) async throws -> URL {
        guard let callbackURLScheme, !callbackURLScheme.isEmpty else {
            throw WebAuthenticationSessionFailure.invalidResponse
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let callback = WebAuthenticationSessionCallbackBridge.make { [weak self] result in
                    self?.finish(result)
                }
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackURLScheme,
                    completionHandler: callback
                )
                session.presentationContextProvider = self
                self.session = session

                if !session.start() {
                    finish(.failure(.unavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: \.isVisible)
            ?? ASPresentationAnchor()
    }

    private func cancel() {
        session?.cancel()
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<URL, WebAuthenticationSessionFailure>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result.mapError { $0 as Error })
    }
}
#endif
