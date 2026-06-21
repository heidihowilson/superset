import Foundation

/// One cloud refresh of the Host-independent surface (PRD §7.2): the Projects that
/// group the browser, the Workspaces within them, and the org's Hosts (the targets a
/// create can be dialed at). `Codable` so the last good result can be cached and
/// painted instantly on the next cold start while a fresh poll runs (ADR-0004).
struct WorkspaceListSnapshot: Sendable, Codable, Equatable {
    var projects: [Project]
    var workspaces: [Workspace]
    var hosts: [HostSummary]
    /// Whether the org is on a paid/trialing plan (`host.checkAccess.paidPlan`), the
    /// org-level gate on Host actions. Carried at the snapshot level — not on a Host or
    /// Workspace row — because the subscription is on the org, so one read settles the
    /// whole list (§11/R5). `nil` when undeterminable (no hosts, or a transient failure).
    var paidPlan: Bool?

    static let empty = WorkspaceListSnapshot(projects: [], workspaces: [], hosts: [])

    init(projects: [Project], workspaces: [Workspace], hosts: [HostSummary] = [], paidPlan: Bool? = nil) {
        self.projects = projects
        self.workspaces = workspaces
        self.hosts = hosts
        self.paidPlan = paidPlan
    }

    private enum CodingKeys: String, CodingKey {
        case projects, workspaces, hosts, paidPlan
    }

    /// `hosts`/`paidPlan` are decoded leniently so a snapshot cached before they existed
    /// still loads (the same forward-compatibility `Workspace.hostID`'s optionality buys)
    /// — a missed poll then refills them. Synthesized `encode(to:)` writes all four keys.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([Project].self, forKey: .projects)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        hosts = try container.decodeIfPresent([HostSummary].self, forKey: .hosts) ?? []
        paidPlan = try container.decodeIfPresent(Bool.self, forKey: .paidPlan)
    }
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
