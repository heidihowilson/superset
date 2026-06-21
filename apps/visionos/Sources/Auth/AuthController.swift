import Foundation
import Observation

/// Where the user stands in the handoff. `RootView` is gated on `.signedIn`.
enum AuthStatus: Equatable {
    /// Reading the Keychain on launch, before we know if a token exists.
    case loading
    case signedOut
    /// The system browser is open and OAuth is in flight.
    case authenticating
    case signedIn
    /// The last attempt failed with a user-presentable message (cancellation aside).
    case failed(String)
}

/// Orchestrates the system-browser token handoff (ADR-0005) and owns the app's
/// auth state. Presentation-agnostic per PRD §6.2: SwiftUI observes `status`/`token`
/// and emits `signIn`/`signOut` intents; it never reaches into the browser, the
/// Keychain, or the network itself.
@MainActor
@Observable
final class AuthController {
    private(set) var status: AuthStatus = .loading
    /// Observable for the UI. `setToken` keeps it and `tokenBox` (read by the bearer
    /// seam off the main actor) in lockstep — assign through that, never directly.
    private(set) var token: AuthToken?

    private let configuration: AuthConfiguration
    private let tokenStore: TokenStore
    private let webAuth: WebAuthenticating
    private let tokenBox = TokenBox()
    /// The `state` issued for the in-flight handoff, validated against the callback.
    private var pendingState: String?

    init(
        configuration: AuthConfiguration = .default,
        tokenStore: TokenStore = KeychainTokenStore(),
        webAuth: WebAuthenticating = WebAuthenticationSessionAuthenticator()
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.webAuth = webAuth
    }

    /// Bearer seam for cloud/relay calls. The client reads the live token through
    /// the shared `TokenBox` rather than retaining the controller, so it stays
    /// `Sendable` and always sees the current token (e.g. after a re-auth).
    func makeAPIClient(http: HTTPPerforming = URLSession.shared) -> AuthAPIClient {
        let tokenBox = tokenBox
        return AuthAPIClient(configuration: configuration, http: http) {
            tokenBox.value
        }
    }

    private func setToken(_ newToken: AuthToken?) {
        token = newToken
        tokenBox.value = newToken
    }

    /// Restore a persisted, unexpired token on launch. No network: a stored token is
    /// trusted until a 401 forces a fresh handoff (there is no refresh endpoint).
    func restore() {
        do {
            if let stored = try tokenStore.load(), !stored.isExpired {
                setToken(stored)
                status = .signedIn
            } else {
                try? tokenStore.clear()
                setToken(nil)
                status = .signedOut
            }
        } catch {
            setToken(nil)
            status = .signedOut
        }
    }

    func signIn(provider: AuthHandoff.Provider) async {
        guard status != .authenticating else { return }
        status = .authenticating

        let state = AuthHandoff.makeStateToken()
        pendingState = state
        let url = AuthHandoff.connectURL(
            configuration: configuration,
            provider: provider,
            state: state
        )

        do {
            let callback = try await webAuth.authenticate(
                url: url,
                callbackScheme: configuration.callbackScheme
            )
            try complete(callbackURL: callback)
        } catch AuthError.userCanceled {
            status = token == nil ? .signedOut : .signedIn
        } catch {
            status = .failed(Self.message(for: error))
        }
        pendingState = nil
    }

    /// Resolve a `superset://auth/callback` deep link that arrived outside the
    /// browser session (a cold-start pending link, PRD §11). Ignored when it is not
    /// a callback or no handoff is in flight.
    func handleDeepLink(_ url: URL) {
        guard url.scheme == configuration.callbackScheme,
              pendingState != nil
        else { return }
        do {
            try complete(callbackURL: url)
        } catch {
            status = .failed(Self.message(for: error))
        }
        pendingState = nil
    }

    func signOut() {
        try? tokenStore.clear()
        setToken(nil)
        pendingState = nil
        status = .signedOut
    }

    private func complete(callbackURL: URL) throws {
        guard let expectedState = pendingState else {
            throw AuthError.stateMismatch
        }
        let parsed = AuthHandoff.parseCallback(
            callbackURL,
            configuration: configuration,
            expectedState: expectedState
        )
        switch parsed {
        case let .success(newToken):
            try tokenStore.save(newToken)
            setToken(newToken)
            status = .signedIn
        case let .failure(error):
            throw error
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AuthError.stateMismatch:
            return "Sign-in could not be verified. Please try again."
        case AuthError.missingToken, AuthError.malformedCallback:
            return "The sign-in response was invalid. Please try again."
        case AuthError.keychain:
            return "Could not securely store your session. Please try again."
        default:
            return "Sign-in failed. Please try again."
        }
    }
}
