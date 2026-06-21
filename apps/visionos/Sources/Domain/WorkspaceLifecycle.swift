import Foundation

/// Create / delete / rename a Workspace (PRD §7.2 lifecycle). The store depends on this
/// seam rather than the transports directly, so previews/tests drive it without the
/// network (PRD §6.2) — mirroring `WorkspaceListProviding` for the read side.
///
/// The split mirrors the host-resilience map (PRD §6.3, ADR-0006): `rename` is a
/// cloud-only mutation (safe Host-offline), while `create`/`delete` run a host-service
/// saga over the relay and are Host-gated by construction (they take a `hostID`).
protocol WorkspaceLifecycleProviding: Sendable {
    /// Cloud-only rename — provisions nothing on the Host, so it succeeds Host-offline.
    func rename(workspaceID: String, to name: String) async throws
    /// Provision a Workspace on `hostID`'s Host over the relay (Host-gated, never queued).
    func create(projectID: String, name: String, hostID: String) async throws
    /// Tear down a Workspace on `hostID`'s Host over the relay (Host-gated, never queued).
    func delete(workspaceID: String, hostID: String) async throws
}

/// The production lifecycle client: rename rides the cloud bearer seam (`AuthAPIClient`),
/// create/delete ride the relay JWT into host-service (`HostServiceClient`), keyed by the
/// `organizationId:machineId` routing key — the same two transports the watch/send paths
/// use (mirrors `apps/web/src/trpc/host-client.ts` + the desktop create path).
///
/// An `actor` because it memoizes the resolved organization id across calls, exactly like
/// `HostChatSender`; the routing key is rebuilt per Host since create/delete target a
/// specific machine.
actor HostWorkspaceLifecycleClient: WorkspaceLifecycleProviding {
    private let api: AuthAPIClient
    private let configuration: AuthConfiguration
    private let http: HTTPPerforming
    private let tokenProvider: RelayTokenProvider

    private var resolvedOrganizationID: String?

    init(
        api: AuthAPIClient,
        configuration: AuthConfiguration,
        http: HTTPPerforming,
        tokenProvider: RelayTokenProvider
    ) {
        self.api = api
        self.configuration = configuration
        self.http = http
        self.tokenProvider = tokenProvider
    }

    func rename(workspaceID: String, to name: String) async throws {
        let organizationID = try await resolveOrganizationID()
        try await api.renameWorkspace(id: workspaceID, name: name, organizationID: organizationID)
    }

    func create(projectID: String, name: String, hostID: String) async throws {
        let organizationID = try await resolveOrganizationID()
        try await hostClient(organizationID: organizationID, hostID: hostID)
            .createWorkspace(projectID: projectID, name: name)
    }

    func delete(workspaceID: String, hostID: String) async throws {
        let organizationID = try await resolveOrganizationID()
        try await hostClient(organizationID: organizationID, hostID: hostID)
            .deleteWorkspace(workspaceID: workspaceID)
    }

    private func hostClient(organizationID: String, hostID: String) -> HostServiceClient {
        HostServiceClient(
            configuration: configuration,
            http: http,
            tokenProvider: tokenProvider,
            routingKey: "\(organizationID):\(hostID)"
        )
    }

    /// The org the Workspace's Host is keyed under — the session's active org, else the
    /// user's first membership (the same resolution the watch/send/list paths use). Cached
    /// after the first call so the routing key is built without a per-op session read.
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
}
