import Foundation

/// Coarse run state surfaced in the Workspace list (cloud tRPC, polled). The list
/// is the one Host-independent surface, so it distinguishes a reachable agent from
/// a Host that is asleep or plan-gated (PRD §6.3, §7.2).
enum WorkspaceStatus: String, Sendable, CaseIterable {
    case running
    case idle
    case hostAsleep
    case planGated
}
