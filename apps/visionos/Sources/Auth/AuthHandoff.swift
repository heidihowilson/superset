import Foundation
import Security

/// Pure logic of the system-browser token handoff (ADR-0005): generate the CSRF
/// `state` nonce, build the `/api/auth/desktop/connect` URL, and parse + validate
/// the `superset://auth/callback` deep link the web success page redirects back.
///
/// No browser, no network, no storage here — that lives in `AuthController` /
/// `WebAuthenticating` / `TokenStore`, so this stays trivially testable.
enum AuthHandoff {
    /// OAuth providers the connect endpoint allows (it rejects anything else).
    enum Provider: String, CaseIterable, Sendable {
        case google
        case github
    }

    /// A 32-byte cryptographically-random, base64url `state`, mirroring the
    /// desktop (`crypto.randomBytes(32).toString("base64url")`). The client holds
    /// it across the browser round-trip and rejects a callback whose `state` differs.
    static func makeStateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // arc4random-backed and still CSPRNG-grade, but a SecRandom failure is an
            // unusual system state worth flagging in debug rather than swallowing.
            assertionFailure("SecRandomCopyBytes failed (status \(status)); using fallback")
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64URLEncodedString()
    }

    /// `…/api/auth/desktop/connect?provider=…&state=…&protocol=superset`.
    static func connectURL(
        configuration: AuthConfiguration,
        provider: Provider,
        state: String
    ) -> URL {
        let connectEndpoint = configuration.apiBaseURL.appendingPathComponent("api/auth/desktop/connect")
        guard var components = URLComponents(url: connectEndpoint, resolvingAgainstBaseURL: false) else {
            preconditionFailure("AuthHandoff.connectURL: \(connectEndpoint) does not parse into URLComponents")
        }
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "protocol", value: configuration.callbackScheme),
        ]
        guard let url = components.url else {
            preconditionFailure("AuthHandoff.connectURL: query components failed to re-serialize from \(connectEndpoint)")
        }
        return url
    }

    /// Validate the captured deep link against `configuration` and the `state` we
    /// issued, returning the minted token. `expiresAt` is an ISO-8601 string; if it
    /// is absent or unparseable we fall back to the 30-day better-auth default so a
    /// malformed timestamp never blocks an otherwise-valid sign-in.
    static func parseCallback(
        _ url: URL,
        configuration: AuthConfiguration,
        expectedState: String
    ) -> Result<AuthToken, AuthError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == configuration.callbackScheme,
              components.host == configuration.callbackHost,
              components.path == configuration.callbackPath
        else {
            return .failure(.malformedCallback)
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard let state = value("state"), !state.isEmpty else {
            return .failure(.malformedCallback)
        }
        guard constantTimeEquals(state, expectedState) else {
            return .failure(.stateMismatch)
        }
        guard let token = value("token"), !token.isEmpty else {
            return .failure(.missingToken)
        }

        let expiresAt = value("expiresAt").flatMap(parseISO8601) ?? defaultExpiry()
        return .success(AuthToken(value: token, expiresAt: expiresAt))
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func defaultExpiry() -> Date {
        Date().addingTimeInterval(60 * 60 * 24 * 30)
    }

    /// Length-aware, branch-flat comparison so `state` validation does not leak the
    /// nonce through timing. Both inputs are app-controlled, but the cost is trivial.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

extension Data {
    /// RFC 4648 §5 base64url, unpadded — the encoding better-auth uses for the nonce.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
