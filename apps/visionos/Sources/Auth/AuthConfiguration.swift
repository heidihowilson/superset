import Foundation

/// Endpoints and identifiers for the system-browser token handoff (ADR-0005).
///
/// V1 reuses the desktop flow verbatim: the client opens
/// `/api/auth/desktop/connect` in a real browser, OAuth runs, the web success page
/// mints a 30-day better-auth session token and deep-links it back via the
/// `superset://auth/callback` URL, which `ASWebAuthenticationSession` captures.
struct AuthConfiguration: Sendable {
    /// Base URL of `apps/api` (`NEXT_PUBLIC_API_URL`). Hosts both
    /// `/api/auth/desktop/connect` and `/api/auth/token`.
    let apiBaseURL: URL

    /// Custom scheme the web success page deep-links back to (`protocol=superset`).
    let callbackScheme: String

    /// Host component of the deep link (`superset://auth/callback`).
    let callbackHost: String

    /// Path component of the deep link (`superset://auth/callback`).
    let callbackPath: String

    static let `default` = AuthConfiguration(
        apiBaseURL: URL(string: "https://api.superset.sh")!,
        callbackScheme: "superset",
        callbackHost: "auth",
        callbackPath: "/callback"
    )

    /// `superset://auth/callback` — the value passed to
    /// `ASWebAuthenticationSession(callbackURLScheme:)` is the scheme alone.
    var callbackURL: URL {
        URL(string: "\(callbackScheme)://\(callbackHost)\(callbackPath)")!
    }
}
