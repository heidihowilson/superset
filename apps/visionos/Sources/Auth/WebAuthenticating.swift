import AuthenticationServices
import Foundation
import UIKit

/// Drives the system browser for one handoff: open `url`, let real Safari run OAuth
/// (Google/GitHub allow this; an embedded WKWebView would be blocked — ADR-0005),
/// and return the `superset://auth/callback` URL once captured. Abstracted so
/// `AuthController` can be exercised without a live browser.
@MainActor
protocol WebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Production adapter over `ASWebAuthenticationSession`. The OS captures the
/// `callbackScheme` redirect itself — the scheme need not (and should not) be
/// claimed in `CFBundleURLTypes` for this path; the Info.plist registration exists
/// only for cold-start deep links handled elsewhere.
@MainActor
final class WebAuthenticationSessionAuthenticator: NSObject, WebAuthenticating {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    let code = (error as? ASWebAuthenticationSessionError)?.code
                    if code == .canceledLogin {
                        continuation.resume(throwing: AuthError.userCanceled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.malformedCallback)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // Reuse Safari's session so an already-signed-in browser skips the OAuth
            // prompt, matching the desktop's real-browser handoff.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }
}

extension WebAuthenticationSessionAuthenticator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window ?? ASPresentationAnchor()
    }
}
