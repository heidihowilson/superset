import Foundation

/// A Mac/Linux machine running host-service where Workspaces physically live and
/// agents execute (CONTEXT.md). Surfaced from the cloud `host.list` read so the
/// create flow can target a specific, online Host — create/delete are Host-gated
/// (worktree provisioning/teardown over the relay, keyed by `machineId`; ADR-0006).
///
/// `Codable` so it rides in the cached `WorkspaceListSnapshot` for instant paint
/// (ADR-0004); `id` is the Host's `machineId`, half of the relay routing key.
struct HostSummary: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
    var online: Bool
}
