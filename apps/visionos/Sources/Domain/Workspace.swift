import Foundation

/// An isolated git worktree on a remote Host where a coding agent runs — the
/// primary unit a user opens, watches, and organizes in space (CONTEXT.md).
///
/// `Codable` so a fetched list can be cached for instant paint on the next cold
/// start (ADR-0004: V1 polls, it does not sync).
struct Workspace: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
    /// The owning Project's id, used to group the browser. Optional because the
    /// cloud row's `projectId` is nullable; such Workspaces fall back to `projectName`.
    var projectID: String?
    var projectName: String
    var status: WorkspaceStatus
    /// The Host's `machineId`, half of the relay routing key
    /// (`organizationId:machineId`) host-service watch/lifecycle calls dial
    /// (PRD §6.4). Optional: the cloud row's `hostId` is nullable, and a
    /// Workspace with no Host can still appear in the list (it just can't be
    /// watched). Optional also keeps an older cached snapshot decodable.
    var hostID: String?
}
