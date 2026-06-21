import Foundation

/// Reads the Host-independent surface over cloud tRPC: `v2Project.list` and
/// `v2Workspace.list`, both bearer-authed `jwtProcedure`s the stored session token
/// satisfies via the better-auth `bearer()` plugin (PRD §7.2, ADR-0005). Reuses the
/// auth client's bearer seam (`authorize`) rather than re-implementing header
/// handling — the pattern AuthAPIClient documents for cloud/relay transports.
///
/// tRPC is invoked over plain HTTP GET (`/api/trpc/<path>?input=…`) with the
/// SuperJSON envelope the server's transformer expects (`{"json": …}` in, and
/// `result.data.json` out). Hand-typed at the boundary per PRD §12.
struct CloudWorkspaceClient: WorkspaceListProviding {
    let api: AuthAPIClient

    func fetchSnapshot() async throws -> WorkspaceListSnapshot {
        let organizationID = try await resolveOrganizationID()

        async let projectRows: [ProjectRow] = query(
            "v2Project.list",
            input: ["organizationId": organizationID]
        )
        async let workspaceRows: [WorkspaceRow] = query(
            "v2Workspace.list",
            input: ["organizationId": organizationID]
        )

        let projects = try await projectRows.map { Project(id: $0.id, name: $0.name) }
        let workspaces = try await workspaceRows.map {
            Workspace(
                id: $0.id,
                name: $0.name,
                projectID: $0.projectId,
                projectName: $0.projectName ?? "",
                status: .unknown
            )
        }
        return WorkspaceListSnapshot(projects: projects, workspaces: workspaces)
    }

    /// The org to scope the list to: the session's active org, else the user's first
    /// membership. Both reads go through the bearer seam already exercised by M0a.
    private func resolveOrganizationID() async throws -> String {
        let session = try await api.fetchSession()
        if let id = session.activeOrganizationID { return id }
        if let first = try await api.listOrganizations().first { return first.id }
        throw AuthError.noActiveOrganization
    }

    private func query<Row: Decodable>(_ path: String, input: [String: String]) async throws -> [Row] {
        let envelope = ["json": input]
        let inputData = try JSONSerialization.data(withJSONObject: envelope)
        let inputString = String(decoding: inputData, as: UTF8.self)

        var components = URLComponents(
            url: api.configuration.apiBaseURL.appendingPathComponent("api/trpc/\(path)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "input", value: inputString)]
        guard let url = components?.url else { throw AuthError.badServerResponse(status: -1) }

        var request = URLRequest(url: url)
        try api.authorize(&request)

        let (data, response) = try await api.http.data(for: request)
        try Self.ensureOK(response)
        return try JSONDecoder().decode(TRPCResult<[Row]>.self, from: data).result.data.json
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

/// The SuperJSON-wrapped tRPC success envelope: `{ "result": { "data": { "json": … } } }`.
private struct TRPCResult<Payload: Decodable>: Decodable {
    struct ResultBox: Decodable {
        struct DataBox: Decodable { let json: Payload }
        let data: DataBox
    }
    let result: ResultBox
}

/// `v2Project.list` row — only the fields the browser groups by are decoded.
private struct ProjectRow: Decodable {
    let id: String
    let name: String
}

/// `v2Workspace.list` row — `projectId`/`projectName` drive grouping; other columns
/// (branch, type, createdAt) are intentionally not decoded until a feature needs them.
private struct WorkspaceRow: Decodable {
    let id: String
    let name: String
    let projectId: String?
    let projectName: String?
}
