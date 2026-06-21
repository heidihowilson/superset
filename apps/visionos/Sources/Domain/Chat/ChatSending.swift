import Foundation

/// Sends prompts into a Workspace's chat session and supplies the composer's pickers.
/// The `ComposerStore` depends on this seam rather than the transport directly, so
/// previews/tests drive it without the network (PRD §6.2) — mirroring
/// `ChatTranscriptProviding` for the watch side.
protocol ChatSending: Sendable {
    /// Send `text` into the client-owned chat session, optionally on a chosen `model`.
    func sendMessage(_ text: String, model: String?) async throws
    /// The cloud's offered models — populates the picker even when the Host is asleep.
    func availableModels() async throws -> [ChatModel]
    /// The Host's configured agent presets — Host-gated, empty when the Host is asleep.
    func availableAgentPresets() async throws -> [AgentPreset]
}

/// The production sender: resolves the org + routing key, registers the client-owned
/// chat session (ADR-0010), and posts `chat.sendMessage` over the relay into the session
/// Watch polls — so a sent prompt appears in the same transcript (the M0d "see the run").
///
/// An `actor` because it memoizes the resolved organization id and one-time session
/// registration across sends, exactly like `HostChatTranscriptProvider`. Constructed from
/// the same `SessionIDStore` as the watch provider, so both address the same per-Workspace
/// `sessionId`.
actor HostChatSender: ChatSending {
    private let api: AuthAPIClient
    private let configuration: AuthConfiguration
    private let http: HTTPPerforming
    private let tokenProvider: RelayTokenProvider
    private let workspaceID: String
    private let hostID: String
    private let sessionID: String

    private var resolvedOrganizationID: String?
    private var sessionEnsured = false

    init(
        api: AuthAPIClient,
        configuration: AuthConfiguration,
        http: HTTPPerforming,
        tokenProvider: RelayTokenProvider,
        sessionIDStore: SessionIDStore,
        workspaceID: String,
        hostID: String
    ) {
        self.api = api
        self.configuration = configuration
        self.http = http
        self.tokenProvider = tokenProvider
        self.workspaceID = workspaceID
        self.hostID = hostID
        self.sessionID = sessionIDStore.sessionID(for: workspaceID)
    }

    func sendMessage(_ text: String, model: String?) async throws {
        let organizationID = try await resolveOrganizationID()
        await ensureSessionRegistered(organizationID: organizationID)
        try await hostClient(organizationID: organizationID).sendMessage(
            sessionID: sessionID,
            workspaceID: workspaceID,
            content: text,
            model: model
        )
    }

    func availableModels() async throws -> [ChatModel] {
        try await api.fetchChatModels()
    }

    func availableAgentPresets() async throws -> [AgentPreset] {
        let organizationID = try await resolveOrganizationID()
        return try await hostClient(organizationID: organizationID).listAgentConfigs()
    }

    private func hostClient(organizationID: String) -> HostServiceClient {
        HostServiceClient(
            configuration: configuration,
            http: http,
            tokenProvider: tokenProvider,
            routingKey: "\(organizationID):\(hostID)"
        )
    }

    /// The org the Workspace's Host is keyed under — the session's active org, else the
    /// user's first membership (the same resolution the watch and cloud list use). Cached
    /// after the first call so the routing key is built without a per-send session read.
    private func resolveOrganizationID() async throws -> String {
        if let resolvedOrganizationID { return resolvedOrganizationID }
        let session = try await api.fetchSession()
        if let id = session.activeOrganizationID {
            resolvedOrganizationID = id
            return id
        }
        if let first = try await api.listOrganizations().first {
            resolvedOrganizationID = first.id
            return first.id
        }
        throw AuthError.noActiveOrganization
    }

    /// Best-effort cloud registration of the client-minted session (ADR-0010). Idempotent
    /// (`onConflictDoNothing`); a failure does not block the send — the Host runtime keys
    /// off `sessionId` directly. The watch provider registers the same id, so this is
    /// usually already settled by the time the first prompt is sent.
    private func ensureSessionRegistered(organizationID: String) async {
        if sessionEnsured { return }
        do {
            try await api.createChatSession(
                sessionID: sessionID,
                workspaceID: workspaceID,
                organizationID: organizationID
            )
            sessionEnsured = true
        } catch {
            // Leave `sessionEnsured` false to retry on the next send.
        }
    }
}
