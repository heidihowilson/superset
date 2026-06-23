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
final class AuthController: RelayCredentialGate {
    private(set) var status: AuthStatus = .loading
    /// Observable for the UI. `setToken` keeps it and `tokenBox` (read by the bearer
    /// seam off the main actor) in lockstep — assign through that, never directly.
    private(set) var token: AuthToken?

    /// Fired on every transition into `.signedOut`. The shared `WorkspaceStore`'s
    /// privacy reset is wired here (in `SupersetApp`) instead of in a view so the
    /// previous account's cache is dropped on any sign-out path — including a sign-out
    /// from the Settings window while the command-center scene is closed.
    var onSignedOut: (() -> Void)?

    private let configuration: AuthConfiguration
    private let tokenStore: TokenStore
    private let webAuth: WebAuthenticating
    private let pendingStateStore: PendingStateStore
    private let tokenBox = TokenBox()
    /// Shared relay/host JWT cache (mint-once-reuse) backing every Workspace watch over
    /// the relay, so the per-Workspace poll loops don't each re-mint (PRD §11). Dropped
    /// on background ahead of the ~1h revocation lag (ADR-0008).
    private let relayTokenProvider: RelayTokenProvider
    /// Client-owned chat session map (`workspaceId → sessionId`, ADR-0010).
    private let sessionIDStore = SessionIDStore()
    /// The `state` issued for the in-flight handoff, validated against the callback.
    /// Mirrored into `pendingStateStore` via `setPendingState` so a callback that
    /// arrives after a cold start (the process was killed mid-OAuth) still validates.
    private var pendingState: String?

    init(
        configuration: AuthConfiguration = .default,
        tokenStore: TokenStore = KeychainTokenStore(),
        webAuth: WebAuthenticating = WebAuthenticationSessionAuthenticator(),
        pendingStateStore: PendingStateStore = UserDefaultsPendingStateStore()
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.webAuth = webAuth
        self.pendingStateStore = pendingStateStore
        self.relayTokenProvider = RelayTokenProvider(
            api: AuthAPIClient(configuration: configuration, tokenProvider: { [tokenBox] in tokenBox.value })
        )
    }

    /// Keep the in-memory nonce and its durable copy in lockstep — assign through
    /// this, never `pendingState` directly, so a cold-start callback can recover it.
    private func setPendingState(_ value: String?) {
        pendingState = value
        if let value {
            pendingStateStore.save(value)
        } else {
            pendingStateStore.clear()
        }
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

    /// Cloud Workspace-list provider for the browser. Built over the same bearer seam
    /// as `makeAPIClient`, so it reads the live token and survives a re-auth.
    func makeWorkspaceListProvider(http: HTTPPerforming = URLSession.shared) -> CloudWorkspaceClient {
        CloudWorkspaceClient(api: makeAPIClient(http: http))
    }

    /// Workspace lifecycle client for the browser (create/delete over the relay, rename
    /// over cloud). Built over the same bearer seam and shared relay JWT cache as the
    /// watch/send paths, so a Host-gated op rides the same minted credential (PRD §6.3/§11).
    func makeWorkspaceLifecycleClient(http: HTTPPerforming = URLSession.shared) -> HostWorkspaceLifecycleClient {
        HostWorkspaceLifecycleClient(
            api: makeAPIClient(http: http),
            configuration: configuration,
            http: http,
            tokenProvider: relayTokenProvider
        )
    }

    /// Watch-transcript provider for a Workspace window — polls `chat.getSnapshot` over
    /// the relay for that Workspace's client-owned session (ADR-0006/0010). Returns nil
    /// when the Workspace has no Host (`hostID`), i.e. nothing to watch; the window then
    /// shows the Host-gated notice instead of a transcript.
    func makeChatTranscriptProvider(
        for workspace: Workspace,
        http: HTTPPerforming = URLSession.shared
    ) -> HostChatTranscriptProvider? {
        guard let hostID = workspace.hostID else { return nil }
        return HostChatTranscriptProvider(
            api: makeAPIClient(http: http),
            configuration: configuration,
            http: http,
            tokenProvider: relayTokenProvider,
            sessionIDStore: sessionIDStore,
            workspaceID: workspace.id,
            hostID: hostID
        )
    }

    /// Prompt sender for a Workspace window — posts `chat.sendMessage` over the relay into
    /// the same client-owned session the watch polls (ADR-0006/0010), built over the same
    /// relay JWT cache and `SessionIDStore` as `makeChatTranscriptProvider` so a sent
    /// prompt lands in the watched transcript. Returns nil when the Workspace has no Host.
    func makeChatSender(
        for workspace: Workspace,
        http: HTTPPerforming = URLSession.shared
    ) -> HostChatSender? {
        guard let hostID = workspace.hostID else { return nil }
        return HostChatSender(
            api: makeAPIClient(http: http),
            configuration: configuration,
            http: http,
            tokenProvider: relayTokenProvider,
            sessionIDStore: sessionIDStore,
            workspaceID: workspace.id,
            hostID: hostID
        )
    }

    /// Drop the cached relay JWT — called on background to shrink the RCE-grade token's
    /// live window ahead of the ~1h revocation lag (PRD §13, ADR-0008). Runs synchronously
    /// (no `Task`) so the JWT is cleared before the scene-phase handler returns and the OS
    /// can suspend the app. The next poll re-mints from the still-stored session token.
    func dropRelayToken() {
        relayTokenProvider.invalidate()
    }

    /// Engage/release the relay-mint gate for the Optic ID lock (ADR-0008). While locked,
    /// the shared provider refuses to mint, so a poll behind the lock screen cannot
    /// re-acquire the RCE-grade JWT until the owner re-authenticates on foreground.
    /// Awaited by `LockController` within the lock transition, so the seal/release reaches
    /// the provider before the visible `LockState` advances. `generation` carries the
    /// lock-state transition order onto the provider so a late call can't reseal the
    /// credential after a newer unlock (or vice versa). The provider applies the seal under
    /// its lock, so this completes synchronously — the gate is engaged before `await` returns.
    func setRelayLocked(_ locked: Bool, generation: Int) async {
        relayTokenProvider.setLocked(locked, generation: generation)
    }

    private func setToken(_ newToken: AuthToken?) {
        token = newToken
        tokenBox.value = newToken
    }

    /// Enter the signed-out state and run its side effects (the cache reset) so every
    /// path that lands here — an explicit sign-out and a launch where `restore()` finds
    /// the token missing/expired — clears the previous account uniformly.
    private func enterSignedOut() {
        status = .signedOut
        onSignedOut?()
    }

    /// Restore a persisted, unexpired token on launch. No network: a stored token is
    /// trusted until a 401 forces a fresh handoff (there is no refresh endpoint).
    func restore() {
        do {
            if let stored = try tokenStore.load(), !stored.isExpired {
                setToken(stored)
                status = .signedIn
                // Already authed — no handoff is in flight, so drop any stale nonce.
                setPendingState(nil)
            } else {
                try? tokenStore.clear()
                setToken(nil)
                enterSignedOut()
                // Recover an interrupted handoff so a pending cold-start callback validates.
                pendingState = pendingStateStore.load()
            }
        } catch {
            setToken(nil)
            enterSignedOut()
            pendingState = pendingStateStore.load()
        }
    }

    func signIn(provider: AuthHandoff.Provider) async {
        guard status != .authenticating else { return }
        status = .authenticating

        let state = AuthHandoff.makeStateToken()
        setPendingState(state)
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
        setPendingState(nil)
    }

    /// Cancel an in-flight handoff (the `SignInView` Cancel affordance). Tears down the
    /// browser session, which resumes its continuation as `userCanceled`, returning `status`
    /// to a retryable idle state via `signIn`'s cancellation branch. A no-op otherwise.
    func cancelSignIn() {
        guard status == .authenticating else { return }
        webAuth.cancel()
    }

    /// Resolve a `superset://auth/callback` deep link that arrived outside the
    /// browser session (a cold-start pending link, PRD §11). Recovers the nonce from
    /// durable storage when the in-memory copy was lost to a process restart. Ignored
    /// when it is not a callback or no handoff is in flight.
    func handleDeepLink(_ url: URL) {
        if pendingState == nil {
            pendingState = pendingStateStore.load()
        }
        guard url.scheme == configuration.callbackScheme,
              pendingState != nil
        else { return }
        do {
            try complete(callbackURL: url)
        } catch {
            status = .failed(Self.message(for: error))
        }
        setPendingState(nil)
    }

    func signOut() {
        try? tokenStore.clear()
        setToken(nil)
        setPendingState(nil)
        enterSignedOut()
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
        case AuthError.cannotPresentBrowser:
            return "Could not open the sign-in browser. Please try again."
        case AuthError.keychain:
            return "Could not securely store your session. Please try again."
        default:
            return "Sign-in failed. Please try again."
        }
    }
}
