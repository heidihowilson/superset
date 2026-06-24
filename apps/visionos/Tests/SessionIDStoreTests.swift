import XCTest
@testable import Superset

/// Coverage for `SessionIDStore` (#96): the per-Workspace mint must be stable across
/// calls, and the reverse `sessionId → workspaceId` lookup that backs
/// `superset://session/<id>` deep links must resolve a minted session back to its
/// Workspace and return `nil` for one nothing on this device owns (ADR-0010).
///
/// The store persists into `UserDefaults.standard`, so each test mints under a unique
/// Workspace id and clears the keys it wrote in `tearDown` to keep the suite hermetic.
final class SessionIDStoreTests: XCTestCase {
    /// `chat.session.v1.` — the store's private key prefix, redeclared here so tearDown
    /// can target exactly the keys a test wrote.
    private let keyPrefix = "chat.session.v1."
    private var writtenWorkspaceIDs: [String] = []

    private func uniqueWorkspaceID() -> String {
        let id = "test-ws-\(UUID().uuidString)"
        writtenWorkspaceIDs.append(id)
        return id
    }

    override func tearDown() {
        for workspaceID in writtenWorkspaceIDs {
            UserDefaults.standard.removeObject(forKey: keyPrefix + workspaceID)
        }
        writtenWorkspaceIDs = []
        super.tearDown()
    }

    func testMintIsStableAcrossCalls() {
        let store = SessionIDStore()
        let workspaceID = uniqueWorkspaceID()

        let first = store.sessionID(for: workspaceID)
        let second = store.sessionID(for: workspaceID)

        XCTAssertEqual(first, second, "the same Workspace must always resolve to the same minted session id")
        XCTAssertFalse(first.isEmpty)
    }

    func testReverseLookupResolvesMintingWorkspace() {
        let store = SessionIDStore()
        let workspaceID = uniqueWorkspaceID()

        let sessionID = store.sessionID(for: workspaceID)

        XCTAssertEqual(
            store.workspaceID(forSession: sessionID),
            workspaceID,
            "a minted session must round-trip back to the Workspace that minted it"
        )
    }

    func testReverseLookupForUnknownSessionReturnsNil() {
        let store = SessionIDStore()
        let unknownSession = "never-minted-\(UUID().uuidString)"

        XCTAssertNil(
            store.workspaceID(forSession: unknownSession),
            "a session no Workspace on this device minted must resolve to nil"
        )
    }

    func testDistinctWorkspacesMintDistinctSessions() {
        let store = SessionIDStore()
        let workspaceA = uniqueWorkspaceID()
        let workspaceB = uniqueWorkspaceID()

        let sessionA = store.sessionID(for: workspaceA)
        let sessionB = store.sessionID(for: workspaceB)

        XCTAssertNotEqual(sessionA, sessionB)
        XCTAssertEqual(store.workspaceID(forSession: sessionA), workspaceA)
        XCTAssertEqual(store.workspaceID(forSession: sessionB), workspaceB)
    }
}
