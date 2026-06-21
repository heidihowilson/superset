import Foundation

/// Coarse status surfaced in the Workspace list (cloud tRPC, polled). The list is the
/// one Host-independent surface (PRD §6.3, §7.2), so what it can honestly know is
/// *reachability* of the owning Host — derived entirely from cloud reads:
/// `host.list` (online flag) and `host.checkAccess` (org plan gate).
///
/// Live run state (`running`/`idle`/done/error) is **Host-gated**: it flows from
/// host-service over the relay and lands with Watch (ADR-0006, §6.3). Those cases
/// stay defined for that milestone but are not produced by the cloud list.
enum WorkspaceStatus: String, Sendable, CaseIterable, Codable {
    /// Host-gated run state (set by Watch, not the cloud list).
    case running
    /// Host-gated run state (set by Watch, not the cloud list).
    case idle
    /// Owning Host is reachable (cloud `host.list.online`), org on a paid plan. The
    /// live run state behind it is Host-gated and arrives with Watch.
    case hostOnline
    /// Owning Host is offline — host calls (watch/prompt/lifecycle) are unavailable.
    case hostAsleep
    /// Org is not on a paid/trialing plan, so host calls 403 regardless of online
    /// state (R5: the indicator distinguishes asleep vs plan-gated).
    case planGated
    /// Cloud host status not yet known (host.list/checkAccess unavailable this poll).
    /// The list still proves the Workspace exists; this is the honest fallback badge.
    case unknown
}
