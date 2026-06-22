import Foundation

/// Browser → relay → host-service tRPC, the same path the desktop/web use
/// (`${relayBaseURL}/hosts/<routingKey>/trpc/<procedure>`, keyed by the
/// `organizationId:machineId` routing key) — mirroring `apps/web/src/trpc/host-client.ts`
/// (PRD §6.4). Authed with the minted relay JWT, not the session bearer: the relay
/// verifies the JWT via JWKS and forwards only while the Host is online and passes
/// `checkHostAccess` (`allowed && paidPlan`). Host-gated by construction (ADR-0006).
///
/// SuperJSON envelope, hand-typed at the boundary (PRD §12): the input is wrapped
/// `{"json": …}` and the output is read from `result.data.json` — the same shape the
/// cloud `CloudWorkspaceClient` decodes. A 401 drops the cached JWT and re-mints once,
/// covering the case where the token aged out mid-poll.
struct HostServiceClient: Sendable {
    let configuration: AuthConfiguration
    let http: HTTPPerforming
    let tokenProvider: RelayTokenProvider
    /// `organizationId:machineId` — the relay's tunnel key (`buildHostRoutingKey`).
    let routingKey: String

    /// One `chat.getSnapshot` poll: display state + messages from a single host-side
    /// runtime acquisition, avoiding the client dual-poll race (host-service §getSnapshot).
    func fetchSnapshot(sessionID: String, workspaceID: String) async throws -> ChatTranscript {
        try await query(
            "chat.getSnapshot",
            method: .get,
            input: ["sessionId": sessionID, "workspaceId": workspaceID]
        )
    }

    /// Send a user prompt into the Workspace's client-owned chat session (ADR-0010), the
    /// session Watch already polls. A tRPC mutation, so POST: the input rides in the body
    /// rather than `?input=` (`apps/web/src/trpc/host-client.ts`). `model` rides as
    /// `metadata.model`; an empty/nil model lets the Host pick its default. The result is
    /// not decoded — the message landing is confirmed by the next `getSnapshot` poll.
    func sendMessage(sessionID: String, workspaceID: String, content: String, model: String?) async throws {
        var input: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID,
            "payload": ["content": content],
        ]
        if let model, !model.isEmpty {
            input["metadata"] = ["model": model]
        }
        _ = try await requestData("chat.sendMessage", method: .post, input: input)
    }

    /// Provision a Workspace on the Host (`workspaces.create`): the Host builds the git
    /// worktree and registers the cloud row itself (the saga lives host-side, mirroring
    /// the desktop create path). Host-gated by construction (relay): a sleeping/unreachable
    /// Host throws, never queued (ADR-0006). The org and Host are carried by the routing key,
    /// so the body only threads `projectId`, `name`, and the chosen `branch`; an empty/nil
    /// branch is omitted and the Host derives one. The result is not decoded — the next list
    /// poll shows the row.
    func createWorkspace(projectID: String, name: String, branch: String?) async throws {
        var input: [String: Any] = ["projectId": projectID]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { input["name"] = trimmedName }
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedBranch, !trimmedBranch.isEmpty { input["branch"] = trimmedBranch }
        _ = try await requestData("workspaces.create", method: .post, input: input)
    }

    /// Tear down a Workspace on the Host (`workspaceCleanup.destroy`): the Host removes the
    /// git worktree and deletes the cloud row (host-side saga, idempotent). Host-gated by
    /// construction (relay). `deleteBranch`/`force` stay false — the default safe teardown
    /// matching the web app; the row's disappearance is confirmed by the next list poll.
    func deleteWorkspace(workspaceID: String) async throws {
        _ = try await requestData(
            "workspaceCleanup.destroy",
            method: .post,
            input: ["workspaceId": workspaceID, "deleteBranch": false, "force": false]
        )
    }

    /// The Host's configured agent presets (`settings.agentConfigs.list`). Host-gated by
    /// construction (relay): a sleeping/unreachable Host throws, which the caller maps to
    /// an empty picker (PRD §7.2). No input — a workspace-independent settings read.
    func listAgentConfigs() async throws -> [AgentPreset] {
        try await query("settings.agentConfigs.list", method: .get, input: nil)
    }

    private enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
    }

    private func query<Payload: Decodable>(
        _ procedure: String,
        method: HTTPMethod,
        input: Any?
    ) async throws -> Payload {
        let data = try await requestData(procedure, method: method, input: input)
        return try JSONDecoder().decode(RelayResult<Payload>.self, from: data).result.data.json
    }

    /// Perform one relay round-trip, re-minting the JWT once on a 401 (the token aged out
    /// or was dropped on background). Returns the raw body so void mutations skip decoding.
    private func requestData(_ procedure: String, method: HTTPMethod, input: Any?) async throws -> Data {
        do {
            return try await send(procedure, method: method, input: input)
        } catch AuthError.badServerResponse(status: 401) {
            await tokenProvider.invalidate()
            return try await send(procedure, method: method, input: input)
        }
    }

    private func send(_ procedure: String, method: HTTPMethod, input: Any?) async throws -> Data {
        let base = configuration.relayBaseURL
            .appendingPathComponent("hosts")
            .appendingPathComponent(routingKey)
            .appendingPathComponent("trpc")
            .appendingPathComponent(procedure)

        // SuperJSON envelope (`{"json": …}`): GET carries it in `?input=`, POST in the body.
        let envelope: Data? = try input.map { try JSONSerialization.data(withJSONObject: ["json": $0]) }

        var request: URLRequest
        switch method {
        case .get:
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            if let envelope {
                let inputString = String(decoding: envelope, as: UTF8.self)
                components?.queryItems = [URLQueryItem(name: "input", value: inputString)]
            }
            guard let url = components?.url else { throw AuthError.badServerResponse(status: -1) }
            request = URLRequest(url: url)
        case .post:
            request = URLRequest(url: base)
            request.httpMethod = method.rawValue
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = envelope
        }

        let token = try await tokenProvider.token()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await http.data(for: request)
        try Self.ensureOK(response)
        return data
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

/// The SuperJSON-wrapped relay/host success envelope: `{ "result": { "data": { "json": … } } }`.
/// SuperJSON `meta` (Date revival, etc.) is intentionally ignored — the hand-typed
/// watch models read the few fields they need from `json` directly.
private struct RelayResult<Payload: Decodable>: Decodable {
    struct ResultBox: Decodable {
        struct DataBox: Decodable { let json: Payload }
        let data: DataBox
    }
    let result: ResultBox
}
