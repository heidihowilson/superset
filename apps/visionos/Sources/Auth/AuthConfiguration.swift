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

    /// Base URL of the host-dialed relay (`NEXT_PUBLIC_RELAY_URL`). Host-service
    /// reads route through `${relayBaseURL}/hosts/<routingKey>/trpc/<procedure>`,
    /// authed with the minted relay JWT (PRD §6.4, §11). Mirrors the desktop/web
    /// default; a per-org/staging override is a later concern.
    let relayBaseURL: URL

    /// Custom scheme the web success page deep-links back to (`protocol=superset`).
    let callbackScheme: String

    /// Host component of the deep link (`superset://auth/callback`).
    let callbackHost: String

    /// Path component of the deep link (`superset://auth/callback`).
    let callbackPath: String

    static let `default` = AuthConfiguration(
        apiBaseURL: URL(string: "https://api.superset.sh")!,
        relayBaseURL: URL(string: "https://relay.superset.sh")!,
        callbackScheme: "superset",
        callbackHost: "auth",
        callbackPath: "/callback"
    )

    /// `superset://auth/callback` — the value passed to
    /// `ASWebAuthenticationSession(callbackURLScheme:)` is the scheme alone.
    ///
    /// The components are mutable, so a non-default config with an empty or invalid
    /// host yields a string `URL(string:)` cannot parse. Return `nil` in that case
    /// rather than force-unwrapping, so a caller fails the flow instead of trapping.
    var callbackURL: URL? {
        URL(string: "\(callbackScheme)://\(callbackHost)\(callbackPath)")
    }
}
