import Foundation

/// Failures across the handoff and bearer-authed calls. `userCanceled` is the
/// expected outcome when the user dismisses the system browser and is surfaced
/// quietly rather than as an error.
enum AuthError: Error, Equatable {
    /// The browser flow was dismissed by the user before completing.
    case userCanceled
    /// The system browser could not be presented — no key window to anchor against, or
    /// `ASWebAuthenticationSession.start()` returned `false`. Surfaced so the attempt fails
    /// loudly instead of leaking the continuation into a forever-spinner.
    case cannotPresentBrowser
    /// The deep link was not a well-formed `superset://auth/callback?token=…`.
    case malformedCallback
    /// The callback's `state` did not match the nonce we generated — possible CSRF.
    case stateMismatch
    /// The callback carried no `token`.
    case missingToken
    /// A bearer-authed request needs a token but none is stored (signed out).
    case notAuthenticated
    /// The signed-in user has no organization to scope a cloud query to.
    case noActiveOrganization
    /// The server returned a non-2xx status or an undecodable body.
    case badServerResponse(status: Int)
    /// The server answered HTTP 200 but the body was a tRPC error envelope
    /// (`{"error":{"json":{"message":…}}}`) rather than a result — an in-band
    /// auth/validation rejection that must be treated as a failure, not mis-decoded
    /// as a successful (empty) payload. Carries the server's message for diagnostics.
    case trpcError(message: String)
    /// A bearer-authed call proved the stored session token itself is dead — a relay-JWT
    /// mint 401, or a host call that 401s even on a freshly minted JWT. Unlike a transient
    /// `badServerResponse`, no retry recovers it: the only path back is re-running the
    /// OAuth handoff, so it drives the app to signed-out (`AuthController.handleSessionExpired`).
    case sessionExpired
    /// A Keychain operation failed with the given `OSStatus`.
    case keychain(status: Int32)
}

extension AuthError {
    /// Shared user-facing copy for the cloud/host failure cases the stores all map the same
    /// way. `notAuthenticated` and `noActiveOrganization` resolve to fixed strings; a relay
    /// 403 uses `hostGated403` when the call site is Host-gated (else it falls through to
    /// `serverStatus`); any other non-2xx uses `serverStatus`; everything else (transport
    /// failure, decode error) uses `fallback`. Each store passes only the copy that differs.
    static func userFacingMessage(
        for error: Error,
        hostGated403: String? = nil,
        serverStatus: (Int) -> String = { "Server returned HTTP \($0)." },
        default fallback: String
    ) -> String {
        switch error {
        case AuthError.notAuthenticated:
            return "Not signed in."
        case AuthError.noActiveOrganization:
            return "No organization available."
        case let AuthError.badServerResponse(status):
            if status == 403, let hostGated403 { return hostGated403 }
            return serverStatus(status)
        default:
            return fallback
        }
    }
}
