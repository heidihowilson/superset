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
    /// A Keychain operation failed with the given `OSStatus`.
    case keychain(status: Int32)
}
