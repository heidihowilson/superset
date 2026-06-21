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

        // Projects + workspaces are the critical surface: a failure here fails the
        // poll. Host status (online + plan gate) is fetched best-effort alongside —
        // it enriches the badge but must never blank the list (PRD §6.3).
        async let projectRows: [ProjectRow] = fetch(
            "v2Project.list",
            input: ["organizationId": organizationID]
        )
        async let workspaceRows: [WorkspaceRow] = fetch(
            "v2Workspace.list",
            input: ["organizationId": organizationID]
        )
        async let onlineByHost: [String: Bool] = fetchOnlineByHost(organizationID)

        let projects = try await projectRows.map { Project(id: $0.id, name: $0.name) }
        let rows = try await workspaceRows
        let hosts = await onlineByHost

        // Plan-gating is org-level (the subscription is on the org), so one
        // host.checkAccess call settles it for the whole list (§11/R5).
        let paidPlan = await resolvePaidPlan(
            organizationID: organizationID,
            anyHostID: rows.compactMap(\.hostId).first
        )

        let workspaces = rows.map { row in
            // Empty `projectName` is the domain's "no embedded project name" sentinel,
            // bucketed under "Other" by the store's grouping. Trim at the boundary so a
            // whitespace-only name can't masquerade as a real (blank) Project group.
            let projectName = row.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Workspace(
                id: row.id,
                name: row.name,
                projectID: row.projectId,
                projectName: projectName,
                status: Self.status(hostID: row.hostId, onlineByHost: hosts, paidPlan: paidPlan),
                hostID: row.hostId
            )
        }
        return WorkspaceListSnapshot(projects: projects, workspaces: workspaces)
    }

    /// Reachability the Host-independent list CAN derive from cloud reads. Live run
    /// state (running/done/error) is Host-gated over the relay and lands with Watch
    /// (ADR-0006, §6.3) — it is intentionally not synthesized here.
    private static func status(
        hostID: String?,
        onlineByHost: [String: Bool],
        paidPlan: Bool?
    ) -> WorkspaceStatus {
        // A known-false plan gate is decisive (host calls 403 regardless of online
        // state). An indeterminate read must not mislabel access, so fall through.
        if paidPlan == false { return .planGated }
        guard let hostID, let online = onlineByHost[hostID] else { return .unknown }
        return online ? .hostOnline : .hostAsleep
    }

    /// `host.list` online flags keyed by machineId — best-effort: a failure degrades
    /// status to `.unknown`, it never fails the list poll.
    private func fetchOnlineByHost(_ organizationID: String) async -> [String: Bool] {
        do {
            let rows: [HostRow] = try await fetch(
                "host.list",
                input: ["organizationId": organizationID]
            )
            return Dictionary(rows.map { ($0.id, $0.online) }, uniquingKeysWith: { _, last in last })
        } catch {
            return [:]
        }
    }

    /// Whether the org is on a paid/trialing plan, via `host.checkAccess` keyed by any
    /// of its hosts (`organizationId:machineId`, the host-routing-key contract). Returns
    /// nil when undeterminable (no hosts, or a transient failure) so a poll hiccup never
    /// mislabels a Workspace as plan-gated.
    private func resolvePaidPlan(organizationID: String, anyHostID: String?) async -> Bool? {
        guard let anyHostID else { return nil }
        do {
            let access: HostAccess = try await fetch(
                "host.checkAccess",
                input: ["hostId": "\(organizationID):\(anyHostID)"]
            )
            return access.paidPlan
        } catch {
            return nil
        }
    }

    /// The org to scope the list to: the session's active org, else the user's first
    /// membership. Both reads go through the bearer seam already exercised by M0a.
    private func resolveOrganizationID() async throws -> String {
        let session = try await api.fetchSession()
        if let id = session.activeOrganizationID { return id }
        if let first = try await api.listOrganizations().first { return first.id }
        throw AuthError.noActiveOrganization
    }

    private func fetch<Payload: Decodable>(_ path: String, input: [String: String]) async throws -> Payload {
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
        return try JSONDecoder().decode(TRPCResult<Payload>.self, from: data).result.data.json
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

/// `v2Workspace.list` row — `projectId`/`projectName` drive grouping; `hostId` keys the
/// reachability status. Other columns (branch, type, createdAt) are intentionally not
/// decoded until a feature needs them.
private struct WorkspaceRow: Decodable {
    let id: String
    let name: String
    let projectId: String?
    let projectName: String?
    let hostId: String?
}

/// `host.list` row — only the online flag (keyed by machineId `id`) is consumed here.
private struct HostRow: Decodable {
    let id: String
    let online: Bool
}

/// `host.checkAccess` result — `paidPlan` is the org plan gate (`allowed` is implied
/// for any listed Workspace, which inner-joins the user's host membership).
private struct HostAccess: Decodable {
    let allowed: Bool
    let paidPlan: Bool
}
