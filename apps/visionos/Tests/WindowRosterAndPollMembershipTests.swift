import XCTest
import os
@testable import Superset

/// Coverage for the two coupled lifecycle-ref-count fixes (#66).
///
/// `OpenWindowsModel` is reference-counted so a stale window's late `onDisappear` — which
/// SwiftUI can fire *after* the replacement window's `onAppear` for the same id on a
/// restore/retarget/rapid-reopen — can't drop an id whose window is still open (which would
/// make "Consolidate Windows" miss it and `openWindowCount` undercount).
///
/// `WorkspaceStore` scene membership is keyed by a per-scene token set rather than a bare
/// counter, so a duplicated activation can't strand the shared 7s poll running with zero
/// visible windows after a single resign.
final class WindowRosterAndPollMembershipTests: XCTestCase {
    // MARK: OpenWindowsModel ref-counting

    /// The headline Consolidate bug: a second `register` (new window) arriving before the
    /// old window's late `unregister` must keep the id open until *every* registration is
    /// balanced — not drop it on the first release.
    @MainActor
    func testReopenBeforeStaleDisappearKeepsIDRegistered() {
        let model = OpenWindowsModel()
        let id = "ws-1"

        model.registerWorkspace(id) // window appears
        model.registerWorkspace(id) // retarget/rapid-reopen: second appear for the same id
        model.unregisterWorkspace(id) // the stale window's late onDisappear

        XCTAssertTrue(model.openWorkspaceIDs.contains(id), "id stays open while a live window holds it")
        XCTAssertEqual(model.openWindowCount, 1)

        model.unregisterWorkspace(id) // the live window finally closes
        XCTAssertFalse(model.openWorkspaceIDs.contains(id))
        XCTAssertEqual(model.openWindowCount, 0)
    }

    /// An unmatched release (no live registration) is a no-op, never a negative count that
    /// would later swallow a real registration.
    @MainActor
    func testUnbalancedUnregisterNeverUnderflows() {
        let model = OpenWindowsModel()

        model.unregisterWorkspace("ghost") // release with no prior register
        XCTAssertEqual(model.openWindowCount, 0)

        model.registerProject("p")
        model.unregisterProject("p")
        model.unregisterProject("p") // extra release past zero
        XCTAssertTrue(model.openProjectIDs.isEmpty)
        XCTAssertEqual(model.openWindowCount, 0)

        model.registerProject("p") // a fresh registration still lands
        XCTAssertEqual(model.openWindowCount, 1)
    }

    /// `openWindowCount` counts distinct open ids across both kinds — the value the
    /// Consolidate menu gates on.
    @MainActor
    func testCountTracksDistinctIDsAcrossKinds() {
        let model = OpenWindowsModel()
        model.registerWorkspace("a")
        model.registerWorkspace("b")
        model.registerProject("p")

        XCTAssertEqual(model.openWindowCount, 3)
        XCTAssertEqual(model.openWorkspaceIDs, ["a", "b"])
        XCTAssertEqual(model.openProjectIDs, ["p"])
    }

    // MARK: WorkspaceStore token-keyed poll membership

    /// The stranded-poll fix: a duplicated `sceneBecameActive` for one scene must not add a
    /// second active reference, so a single `sceneResignedActive` stops the shared poll. With
    /// the old integer counter this double-activation left the loop running with no visible
    /// window until termination.
    @MainActor
    func testDuplicateActivationDoesNotStrandPollAfterSingleResign() async throws {
        let provider = CountingListProvider()
        let store = WorkspaceStore(provider: provider, pollInterval: .milliseconds(40))
        let token = UUID()

        store.beginPolling(token: token)
        store.sceneBecameActive(token: token)
        store.sceneBecameActive(token: token) // duplicate/unbalanced lifecycle callback

        try await Task.sleep(for: .milliseconds(160))
        XCTAssertGreaterThan(provider.count, 0, "poll should run while the scene is active")

        store.sceneResignedActive(token: token) // a single resign balances the scene
        try await Task.sleep(for: .milliseconds(120)) // let any in-flight fetch + cancellation settle
        let baseline = provider.count
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(provider.count, baseline, "poll must stop once the last active scene resigns")
    }

    /// An unmatched `endPolling`/`sceneResignedActive` (unknown token) is logged and ignored,
    /// never tearing down a healthy poll that other windows still hold.
    @MainActor
    func testUnknownTokenReleaseLeavesHealthyPollRunning() async throws {
        let provider = CountingListProvider()
        let store = WorkspaceStore(provider: provider, pollInterval: .milliseconds(40))
        let token = UUID()

        store.beginPolling(token: token)
        store.sceneBecameActive(token: token)

        store.endPolling(token: UUID()) // stray release for a window that never registered
        store.sceneResignedActive(token: UUID()) // stray resign for a scene that never activated

        try await Task.sleep(for: .milliseconds(120))
        let mid = provider.count
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertGreaterThan(provider.count, mid, "the real window's poll keeps running through stray releases")
    }
}

/// Counts `fetchSnapshot` calls so a test can observe whether the shared poll is running.
private final class CountingListProvider: WorkspaceListProviding {
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    var count: Int { counter.withLock { $0 } }

    func fetchSnapshot() async throws -> WorkspaceListSnapshot {
        counter.withLock { $0 += 1 }
        return .empty
    }
}
