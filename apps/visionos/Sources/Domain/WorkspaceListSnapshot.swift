import Foundation

/// One cloud refresh of the Host-independent surface (PRD §7.2): the Projects that
/// group the browser and the Workspaces within them. `Codable` so the last good
/// result can be cached and painted instantly on the next cold start while a fresh
/// poll runs (ADR-0004).
struct WorkspaceListSnapshot: Sendable, Codable, Equatable {
    var projects: [Project]
    var workspaces: [Workspace]

    static let empty = WorkspaceListSnapshot(projects: [], workspaces: [])
}

/// Supplies the Workspace list. The store depends on this seam rather than the cloud
/// client directly, so previews/tests can drive it without the network (PRD §6.2).
protocol WorkspaceListProviding: Sendable {
    func fetchSnapshot() async throws -> WorkspaceListSnapshot
}

/// Durable last-result store for cached-first paint. A miss (no prior result) returns
/// nil; the store then paints empty until the first poll lands.
protocol WorkspaceListCaching: Sendable {
    func load() -> WorkspaceListSnapshot?
    func save(_ snapshot: WorkspaceListSnapshot)
    /// Drop the persisted snapshot so a different account/org can't paint it on the
    /// next launch. Best-effort, like `save`.
    func clear()
}
