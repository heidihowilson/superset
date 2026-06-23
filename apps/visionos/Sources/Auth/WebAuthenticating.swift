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
    /// Tear down an in-flight session and resume its continuation as `userCanceled`,
    /// returning the caller to a retryable state. A no-op when nothing is in flight.
    func cancel()
}

/// The slice of `ASWebAuthenticationSession` the authenticator drives. Abstracted so the
/// failure paths that otherwise leak the continuation into a forever-spinner — `start()`
/// returning `false`, a missing presentation anchor — can be exercised without a live
/// browser. `ASWebAuthenticationSession` conforms directly.
@MainActor
protocol WebAuthSession: AnyObject {
    var presentationContextProvider: ASWebAuthenticationPresentationContextProviding? { get set }
    var prefersEphemeralWebBrowserSession: Bool { get set }
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: WebAuthSession {}

/// Builds the `WebAuthSession` for a handoff. Defaults to a real `ASWebAuthenticationSession`;
/// tests inject a fake to drive the start-failure and cancel paths deterministically.
typealias WebAuthSessionFactory = @MainActor (
    _ url: URL,
    _ callbackScheme: String,
    _ completion: @escaping (URL?, Error?) -> Void
) -> WebAuthSession

/// Resolves the window to anchor the browser sheet to, or `nil` when none is presentable.
/// Injected so the missing-anchor and present paths are testable without a live key window.
typealias PresentationAnchorResolving = @MainActor () -> ASPresentationAnchor?

/// Production adapter over `ASWebAuthenticationSession`. The OS captures the
/// `callbackScheme` redirect itself — the scheme need not (and should not) be
/// claimed in `CFBundleURLTypes` for this path; the Info.plist registration exists
/// only for cold-start deep links handled elsewhere.
@MainActor
final class WebAuthenticationSessionAuthenticator: NSObject, WebAuthenticating {
    private let makeSession: WebAuthSessionFactory
    private let resolveAnchor: PresentationAnchorResolving
    private var session: WebAuthSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var anchor: ASPresentationAnchor?

    init(
        makeSession: @escaping WebAuthSessionFactory = { url, callbackScheme, completion in
            ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
        },
        resolveAnchor: @escaping PresentationAnchorResolving = WebAuthenticationSessionAuthenticator.keyWindow
    ) {
        self.makeSession = makeSession
        self.resolveAnchor = resolveAnchor
        super.init()
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            // Resolve a real presentation anchor up front. A fabricated `ASPresentationAnchor()`
            // can present against an invalid visionOS scene and never resume, so fail loudly
            // here instead of starting a session that can never complete.
            guard let anchor = resolveAnchor() else {
                resume(throwing: AuthError.cannotPresentBrowser)
                return
            }
            self.anchor = anchor

            let session = makeSession(url, callbackScheme) { [weak self] callbackURL, error in
                // `ASWebAuthenticationSession` invokes its completion on the main thread.
                MainActor.assumeIsolated {
                    self?.complete(callbackURL: callbackURL, error: error)
                }
            }
            session.presentationContextProvider = self
            // Reuse Safari's session so an already-signed-in browser skips the OAuth
            // prompt, matching the desktop's real-browser handoff.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            // `start()` returns `false` when the session can't be presented; its completion
            // handler never fires in that case, so resume here or the continuation leaks.
            if !session.start() {
                resume(throwing: AuthError.cannotPresentBrowser)
            }
        }
    }

    func cancel() {
        session?.cancel()
        resume(throwing: AuthError.userCanceled)
    }

    private func complete(callbackURL: URL?, error: Error?) {
        if let error {
            let code = (error as? ASWebAuthenticationSessionError)?.code
            resume(throwing: code == .canceledLogin ? AuthError.userCanceled : error)
            return
        }
        guard let callbackURL else {
            resume(throwing: AuthError.malformedCallback)
            return
        }
        resume(returning: callbackURL)
    }

    /// Resume the pending continuation exactly once and drop the session. Guards every
    /// terminal path (completion, start-failure, missing-anchor, cancel) against a
    /// double-resume — a second call after the first finds no continuation and no-ops.
    private func resume(returning url: URL) {
        guard let continuation else { return }
        finish()
        continuation.resume(returning: url)
    }

    private func resume(throwing error: Error) {
        guard let continuation else { return }
        finish()
        continuation.resume(throwing: error)
    }

    private func finish() {
        continuation = nil
        session = nil
        anchor = nil
    }

    /// The real key window's scene, or `nil` when none is presentable — never a fabricated
    /// anchor. `nil` gates the handoff into a thrown error rather than a dead session.
    private static func keyWindow() -> ASPresentationAnchor? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
    }
}

extension WebAuthenticationSessionAuthenticator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `authenticate` resolves and stores the anchor before `start()`, and throws when none
        // exists, so the session is only presented once `anchor` is set — the coalesce is an
        // unreachable last resort kept only to satisfy the non-optional return.
        anchor ?? ASPresentationAnchor()
    }
}
