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

    /// Read the current better-auth session (`/api/auth/get-session`) — the cheapest
    /// proof the stored bearer token authenticates against the cloud, and the source
    /// of the session's `activeOrganizationId` (which org `setActiveOrganization`
    /// switches without re-auth).
    func fetchSession() async throws -> SessionInfo {
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent("api/auth/get-session"))
        try authorize(&request)

        let (data, response) = try await http.data(for: request)
        try Self.ensureOK(response)
        struct Payload: Decodable {
            struct Session: Decodable { let activeOrganizationId: String? }
            struct User: Decodable { let email: String? }
            let session: Session?
            let user: User?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return SessionInfo(
            activeOrganizationID: payload.session?.activeOrganizationId,
            userEmail: payload.user?.email
        )
    }

    /// The organizations the signed-in user belongs to (`/api/auth/organization/list`,
    /// better-auth organization plugin) — the candidates for an active-org switch.
    func listOrganizations() async throws -> [OrganizationSummary] {
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent("api/auth/organization/list"))
        try authorize(&request)

        let (data, response) = try await http.data(for: request)
        try Self.ensureOK(response)
        return try JSONDecoder().decode([OrganizationSummary].self, from: data)
    }

    /// Register a client-minted chat session cloud-side (`chat.createSession`, a
    /// SuperJSON tRPC mutation). V1 chat is client-owned (ADR-0010): the visionOS
    /// client supplies the `sessionId` (a persisted UUID) and the row is created
    /// `onConflictDoNothing`, so this is idempotent and safe to call on every open.
    /// The session's active org is settled by the `x-superset-organization-id`
    /// override so the row lands under the Workspace's organization.
    func createChatSession(sessionID: String, workspaceID: String, organizationID: String) async throws {
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent("api/trpc/chat.createSession"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let envelope = ["json": ["sessionId": sessionID, "v2WorkspaceId": workspaceID]]
        request.httpBody = try JSONSerialization.data(withJSONObject: envelope)
        try authorize(&request, organizationID: organizationID)

        let (_, response) = try await http.data(for: request)
        try Self.ensureOK(response)
    }

    /// Rename a Workspace (`v2Workspace.update`, a SuperJSON tRPC mutation). Cloud-only
    /// and therefore safe while the Host is offline (PRD §6.3, ADR-0006) — unlike
    /// create/delete it provisions nothing on the Host. Scoped by the
    /// `x-superset-organization-id` header (the procedure requires an active org) so the
    /// rename lands even when the session has no active org set. The result row is not
    /// decoded; the next list poll reflects the new name. Hand-typed at the boundary (§12).
    func renameWorkspace(id: String, name: String, organizationID: String) async throws {
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent("api/trpc/v2Workspace.update"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let envelope = ["json": ["id": id, "name": name]]
        request.httpBody = try JSONSerialization.data(withJSONObject: envelope)
        try authorize(&request, organizationID: organizationID)

        let (_, response) = try await http.data(for: request)
        try Self.ensureOK(response)
    }

    /// The cloud's offered chat models (`chat.getModels`, a no-input SuperJSON tRPC
    /// query). Cloud-sourced, so the composer's model picker populates even when the
    /// Workspace's Host is asleep (PRD §7.2). Hand-typed at the boundary (PRD §12).
    func fetchChatModels() async throws -> [ChatModel] {
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent("api/trpc/chat.getModels"))
        try authorize(&request)

        let (data, response) = try await http.data(for: request)
        try Self.ensureOK(response)
        struct Payload: Decodable {
            struct ResultBox: Decodable {
                struct DataBox: Decodable {
                    struct Models: Decodable { let models: [ChatModel] }
                    let json: Models
                }
                let data: DataBox
            }
            let result: ResultBox
        }
        return try JSONDecoder().decode(Payload.self, from: data).result.data.json.models
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

/// The slice of the better-auth session the M0a connectivity check surfaces: who is
/// signed in and which org is active. Hand-typed at the boundary (PRD §12) — the
/// full cloud tRPC contract with SuperJSON models lands with the workspace list.
struct SessionInfo: Sendable, Equatable {
    let activeOrganizationID: String?
    let userEmail: String?
}

/// A membership candidate for an active-org switch.
struct OrganizationSummary: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
}
