import Foundation

/// Minimal HTTP performer so request building can be tested without the network and
/// `URLSession` injected in production.
protocol HTTPPerforming: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPPerforming {}

/// The bearer seam every authenticated call goes through (PRD §11). It stamps
/// `Authorization: Bearer <token>` (the enabled better-auth `bearer()` plugin
/// resolves the session) plus the optional `x-superset-organization-id` override,
/// and exposes the two auth-scoped endpoints this milestone owns: minting the
/// relay/host JWT and switching the active org. Cloud tRPC and host-over-relay
/// transports (a later milestone, gated on hand-typed SuperJSON models) reuse
/// `authorize(_:)` rather than re-implementing header handling.
struct AuthAPIClient: Sendable {
    let configuration: AuthConfiguration
    let http: HTTPPerforming
    /// Returns the current session token, or nil when signed out.
    let tokenProvider: @Sendable () -> AuthToken?

    init(
        configuration: AuthConfiguration,
        http: HTTPPerforming = URLSession.shared,
        tokenProvider: @escaping @Sendable () -> AuthToken?
    ) {
        self.configuration = configuration
        self.http = http
        self.tokenProvider = tokenProvider
    }

    /// Stamp the bearer header (and an optional active-org override) onto a request.
    /// Throws `notAuthenticated` when no token is stored so callers fail loudly
    /// rather than firing an unauthenticated request.
    func authorize(_ request: inout URLRequest, organizationID: String? = nil) throws {
        guard let token = tokenProvider() else { throw AuthError.notAuthenticated }
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        if let organizationID {
            request.setValue(organizationID, forHTTPHeaderField: "x-superset-organization-id")
        }
    }

    /// Exchange the session token for a short-lived RS256 JWT (`/api/auth/token`,
    /// 1-hour TTL, carries `organizationIds`) — the credential relay/host-service
    /// calls present. No refresh endpoint exists; on 401 the handoff re-runs.
    func mintRelayJWT() async throws -> String {
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent("api/auth/token"))
        try authorize(&request)

        let (data, response) = try await http.data(for: request)
        try Self.ensureOK(response)
        struct TokenResponse: Decodable { let token: String }
        return try JSONDecoder().decode(TokenResponse.self, from: data).token
    }

    /// Set the session's `activeOrganizationId` via the better-auth organization
    /// plugin (`/api/auth/organization/set-active`). The active org is the session's
    /// value, not a JWT claim (ADR-0005), so switching needs no re-auth.
    func setActiveOrganization(id: String) async throws {
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent("api/auth/organization/set-active"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["organizationId": id])
        try authorize(&request)

        let (_, response) = try await http.data(for: request)
        try Self.ensureOK(response)
    }

    private static func ensureOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.badServerResponse(status: -1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.badServerResponse(status: http.statusCode)
        }
    }
}
