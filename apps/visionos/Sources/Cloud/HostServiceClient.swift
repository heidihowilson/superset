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
            input: ["sessionId": sessionID, "workspaceId": workspaceID]
        )
    }

    private func query<Payload: Decodable>(_ procedure: String, input: [String: String]) async throws -> Payload {
        do {
            return try await send(procedure, input: input)
        } catch AuthError.badServerResponse(status: 401) {
            // The relay JWT aged out (or was dropped on background): re-mint once.
            await tokenProvider.invalidate()
            return try await send(procedure, input: input)
        }
    }

    private func send<Payload: Decodable>(_ procedure: String, input: [String: String]) async throws -> Payload {
        let envelope = ["json": input]
        let inputData = try JSONSerialization.data(withJSONObject: envelope)
        let inputString = String(decoding: inputData, as: UTF8.self)

        let base = configuration.relayBaseURL
            .appendingPathComponent("hosts")
            .appendingPathComponent(routingKey)
            .appendingPathComponent("trpc")
            .appendingPathComponent(procedure)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "input", value: inputString)]
        guard let url = components?.url else { throw AuthError.badServerResponse(status: -1) }

        var request = URLRequest(url: url)
        let token = try await tokenProvider.token()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await http.data(for: request)
        try Self.ensureOK(response)
        return try JSONDecoder().decode(RelayResult<Payload>.self, from: data).result.data.json
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
