import Foundation

/// Supplies a Workspace's watch transcript. The `ChatSessionStore` depends on this
/// seam rather than the relay transport directly, so previews/tests drive it without
/// the network (PRD §6.2), mirroring `WorkspaceListProviding` for the cloud list.
protocol ChatTranscriptProviding: Sendable {
    func fetchTranscript() async throws -> ChatTranscript
}

/// The production provider: resolves the org + routing key, registers the
/// client-owned chat session (ADR-0010), and polls `chat.getSnapshot` over the relay.
///
/// An `actor` because it memoizes the resolved organization id and one-time session
/// registration across poll ticks — the org read and `createSession` happen once, not
/// every 2 seconds. Watch is Host-gated: a non-online/plan-gated Host surfaces as a
/// thrown error the store renders as a notice, never as blanked data.
actor HostChatTranscriptProvider: ChatTranscriptProviding {
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

    func fetchTranscript() async throws -> ChatTranscript {
        let organizationID = try await resolveOrganizationID()
        try await ensureSessionRegistered(organizationID: organizationID)

        let client = HostServiceClient(
            configuration: configuration,
            http: http,
            tokenProvider: tokenProvider,
            routingKey: "\(organizationID):\(hostID)"
        )
        return try await client.fetchSnapshot(sessionID: sessionID, workspaceID: workspaceID)
    }

    /// The org the Workspace's Host is keyed under — the session's active org, else the
    /// user's first membership (the same resolution the cloud list uses). Cached after
    /// the first poll so the routing key is built without a per-tick session read.
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

    /// Best-effort cloud registration of the client-minted session (ADR-0010).
    /// Idempotent (`onConflictDoNothing`) and retried until it lands; a failure does
    /// not block watching — the Host runtime keys off `sessionId` directly, so a
    /// `createSession` hiccup must never blank the transcript.
    private func ensureSessionRegistered(organizationID: String) async throws {
        if sessionEnsured { return }
        do {
            try await api.createChatSession(
                sessionID: sessionID,
                workspaceID: workspaceID,
                organizationID: organizationID
            )
            sessionEnsured = true
        } catch is CancellationError {
            // Cancellation isn't a registration failure — propagate it so the poll
            // honors the cancellation contract instead of pressing on to fetch.
            throw CancellationError()
        } catch {
            // Leave `sessionEnsured` false to retry on the next poll.
        }
    }
}
