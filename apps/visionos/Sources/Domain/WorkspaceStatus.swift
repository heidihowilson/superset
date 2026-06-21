import Foundation

/// Coarse run state surfaced in the Workspace list (cloud tRPC, polled). The list
/// is the one Host-independent surface, so it distinguishes a reachable agent from
/// a Host that is asleep or plan-gated (PRD §6.3, §7.2).
enum WorkspaceStatus: String, Sendable, CaseIterable, Codable {
    case running
    case idle
    case hostAsleep
    case planGated
    /// Listed from the cloud, but its live run state is not yet known: run status
    /// (running/done/error) flows from host-service over the relay, which is
    /// Host-gated and lands with Watch (ADR-0006). The cloud list proves the
    /// Workspace exists; this is the honest badge until the Host fills it in.
    case unknown
}
