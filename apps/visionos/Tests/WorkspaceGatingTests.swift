import XCTest
@testable import Superset

/// Coverage for `WorkspaceStore.canCreate(onHostID:)` and `canDelete(_:)` (issue #99), the
/// Host-gating contract that refuses a relay call already known to 403 (PRD §6.3). The store
/// is seeded through the cache seam — `init` paints the cached snapshot (hosts + `paidPlan`)
/// synchronously, so the gates can be exercised without a provider/poll. Lifecycle wiring is
/// modelled by injecting (or omitting) a no-op `WorkspaceLifecycleProviding`, since both gates
/// first require `lifecycle != nil`.
@MainActor
final class WorkspaceGatingTests: XCTestCase {
    /// A `WorkspaceListCaching` returning a fixed snapshot — the store paints it on `init`,
    /// mirroring the sample seam used for previews.
    private struct FixedCache: WorkspaceListCaching {
        let snapshot: WorkspaceListSnapshot
        func load() -> WorkspaceListSnapshot? { snapshot }
        func save(_ snapshot: WorkspaceListSnapshot) {}
        func clear() {}
    }

    /// A no-op lifecycle whose only role is to make `lifecycle != nil` true (the gates never
    /// invoke it — they only check that a real client is wired).
    private struct NoopLifecycle: WorkspaceLifecycleProviding {
        func rename(workspaceID: String, to name: String) async throws {}
        func create(projectID: String, name: String, branch: String, hostID: String) async throws {}
        func delete(workspaceID: String, hostID: String) async throws {}
    }

    private func makeStore(
        hosts: [HostSummary] = [],
        paidPlan: Bool? = nil,
        workspaces: [Workspace] = [],
        lifecycleWired: Bool = true
    ) -> WorkspaceStore {
        WorkspaceStore(
            lifecycle: lifecycleWired ? NoopLifecycle() : nil,
            cache: FixedCache(snapshot: WorkspaceListSnapshot(
                projects: [],
                workspaces: workspaces,
                hosts: hosts,
                paidPlan: paidPlan
            ))
        )
    }

    private func host(_ id: String, online: Bool) -> HostSummary {
        HostSummary(id: id, name: id, online: online)
    }

    private func workspace(status: WorkspaceStatus, hostID: String? = "host-1") -> Workspace {
        Workspace(id: "w-1", name: "ws", projectID: nil, projectName: "P", status: status, hostID: hostID)
    }

    // MARK: canCreate

    /// The happy path: lifecycle wired, an online Host present, and the org on a plan.
    func testCanCreateTrueForOnlineHostOnPlan() {
        let store = makeStore(hosts: [host("host-1", online: true)], paidPlan: true)
        XCTAssertTrue(store.canCreate(onHostID: "host-1"))
    }

    /// An undeterminable plan (`nil`) is allowed through — only a *known-false* plan refuses,
    /// matching how delete gates on the Workspace status.
    func testCanCreateTrueForOnlineHostWhenPlanUnknown() {
        let store = makeStore(hosts: [host("host-1", online: true)], paidPlan: nil)
        XCTAssertTrue(store.canCreate(onHostID: "host-1"))
    }

    /// A known non-paid plan refuses the create even with an online Host present.
    func testCanCreateFalseWhenPlanNotPaid() {
        let store = makeStore(hosts: [host("host-1", online: true)], paidPlan: false)
        XCTAssertFalse(store.canCreate(onHostID: "host-1"))
    }

    /// An offline Host never reaches `onlineHosts`, so create is refused.
    func testCanCreateFalseForOfflineHost() {
        let store = makeStore(hosts: [host("host-1", online: false)], paidPlan: true)
        XCTAssertFalse(store.canCreate(onHostID: "host-1"))
    }

    /// A `hostID` absent from the list (e.g. a stale create-sheet selection after the poll
    /// dropped the Host) is refused.
    func testCanCreateFalseForAbsentHost() {
        let store = makeStore(hosts: [host("host-1", online: true)], paidPlan: true)
        XCTAssertFalse(store.canCreate(onHostID: "host-missing"))
    }

    /// No lifecycle wired (the preview/sample store) refuses regardless of host/plan.
    func testCanCreateFalseWhenLifecycleNotWired() {
        let store = makeStore(hosts: [host("host-1", online: true)], paidPlan: true, lifecycleWired: false)
        XCTAssertFalse(store.canCreate(onHostID: "host-1"))
    }

    // MARK: canDelete

    /// Delete is allowed when lifecycle is wired, the Workspace has an owning Host, and its
    /// status reports the Host online on a plan.
    func testCanDeleteTrueForHostOnline() {
        let store = makeStore()
        XCTAssertTrue(store.canDelete(workspace(status: .hostOnline)))
    }

    /// The Host-gated run states (`.running`/`.idle`) only land while the Host is reachable,
    /// so they also permit delete.
    func testCanDeleteTrueForRunningAndIdle() {
        let store = makeStore()
        XCTAssertTrue(store.canDelete(workspace(status: .running)))
        XCTAssertTrue(store.canDelete(workspace(status: .idle)))
    }

    /// Statuses the client already knows aren't host-online refuse the relay call.
    func testCanDeleteFalseForNonHostOnlineStatuses() {
        let store = makeStore()
        for status in [WorkspaceStatus.hostAsleep, .planGated, .unknown] {
            XCTAssertFalse(store.canDelete(workspace(status: status)), "\(status) must refuse delete")
        }
    }

    /// A Workspace with no owning Host can't be torn down over the relay.
    func testCanDeleteFalseWhenHostIDNil() {
        let store = makeStore()
        XCTAssertFalse(store.canDelete(workspace(status: .hostOnline, hostID: nil)))
    }

    /// No lifecycle wired refuses even an otherwise-deletable Workspace.
    func testCanDeleteFalseWhenLifecycleNotWired() {
        let store = makeStore(lifecycleWired: false)
        XCTAssertFalse(store.canDelete(workspace(status: .hostOnline)))
    }
}
