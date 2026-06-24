import XCTest
@testable import Superset

/// Coverage for `WorkspaceStore.createWorkspace`'s input validation (issue #107). The Host gate
/// (`canCreate`) only checks Host/plan reachability; before #107 a blank name still forwarded to
/// the relay saga, provisioning a Host-side worktree with an empty name or a guaranteed server
/// error. The store now mirrors `rename`'s guard: a blank (trimmed) name or empty `projectID`
/// surfaces `lifecycleError` and never reaches `lifecycle.create`.
@MainActor
final class WorkspaceCreateValidationTests: XCTestCase {
    /// A lifecycle spy recording whether `create` was invoked, so a guarded call can be asserted
    /// to never reach the relay. An actor mirrors the real `HostWorkspaceLifecycleClient` and
    /// satisfies the `Sendable` protocol.
    private actor SpyLifecycle: WorkspaceLifecycleProviding {
        private(set) var createCalled = false
        func rename(workspaceID: String, to name: String) async throws {}
        func create(projectID: String, name: String, branch: String, hostID: String) async throws {
            createCalled = true
        }
        func delete(workspaceID: String, hostID: String) async throws {}
    }

    private struct FixedCache: WorkspaceListCaching {
        let snapshot: WorkspaceListSnapshot
        func load() -> WorkspaceListSnapshot? { snapshot }
        func save(_ snapshot: WorkspaceListSnapshot) {}
        func clear() {}
    }

    /// A store whose Host gate passes (online Host on a plan), so validation is the only thing
    /// that can refuse the create.
    private func makeStore(lifecycle: SpyLifecycle) -> WorkspaceStore {
        WorkspaceStore(
            lifecycle: lifecycle,
            cache: FixedCache(snapshot: WorkspaceListSnapshot(
                projects: [],
                workspaces: [],
                hosts: [HostSummary(id: "host-1", name: "host-1", online: true)],
                paidPlan: true
            ))
        )
    }

    /// A blank name surfaces the validation error and never forwards to the relay.
    func testCreateWorkspaceWithBlankNameSetsErrorAndSkipsLifecycle() async {
        let spy = SpyLifecycle()
        let store = makeStore(lifecycle: spy)

        await store.createWorkspace(projectID: "proj-1", name: "   ", branch: "main", hostID: "host-1")

        let createCalled = await spy.createCalled
        XCTAssertFalse(createCalled, "a blank name must never reach lifecycle.create")
        XCTAssertNotNil(store.lifecycleError)
        XCTAssertFalse(store.isCreatingWorkspace)
    }

    /// An empty projectID is likewise refused before the relay call.
    func testCreateWorkspaceWithEmptyProjectIDSetsErrorAndSkipsLifecycle() async {
        let spy = SpyLifecycle()
        let store = makeStore(lifecycle: spy)

        await store.createWorkspace(projectID: "", name: "My Workspace", branch: "main", hostID: "host-1")

        let createCalled = await spy.createCalled
        XCTAssertFalse(createCalled, "an empty projectID must never reach lifecycle.create")
        XCTAssertNotNil(store.lifecycleError)
    }

    /// A valid name forwards to the relay (the guard doesn't block legitimate creates).
    func testCreateWorkspaceWithValidNameForwardsToLifecycle() async {
        let spy = SpyLifecycle()
        let store = makeStore(lifecycle: spy)

        await store.createWorkspace(projectID: "proj-1", name: "My Workspace", branch: "main", hostID: "host-1")

        let createCalled = await spy.createCalled
        XCTAssertTrue(createCalled, "a valid name must forward to lifecycle.create")
    }
}
