import XCTest
@testable import Superset

/// Coverage for `WorkspaceStore.groups` (issue #94), the browser's bucketing rule: Projects
/// render in list order (empty ones still show), a Workspace with no/missing Project falls
/// back to its embedded `projectName` (else "Other"), and rows sort case-insensitively. The
/// store is seeded through the cache seam — `init` paints the cached snapshot synchronously,
/// so no provider/poll is needed to exercise the computed grouping.
@MainActor
final class WorkspaceGroupingTests: XCTestCase {
    /// A `WorkspaceListCaching` returning a fixed snapshot, mirroring the sample seam the
    /// store already uses for previews — the store paints it on `init`.
    private struct FixedCache: WorkspaceListCaching {
        let snapshot: WorkspaceListSnapshot
        func load() -> WorkspaceListSnapshot? { snapshot }
        func save(_ snapshot: WorkspaceListSnapshot) {}
        func clear() {}
    }

    private func makeStore(projects: [Project], workspaces: [Workspace]) -> WorkspaceStore {
        WorkspaceStore(cache: FixedCache(snapshot: WorkspaceListSnapshot(projects: projects, workspaces: workspaces)))
    }

    private func workspace(_ id: String, _ name: String, projectID: String? = nil, projectName: String = "") -> Workspace {
        Workspace(id: id, name: name, projectID: projectID, projectName: projectName, status: .hostOnline, hostID: nil)
    }

    /// Groups follow Project list order (not alphabetical), and a Project with no Workspaces
    /// still renders as an empty group so the user knows it exists.
    func testProjectOrderPreservedAndEmptyProjectRendersAsEmptyGroup() {
        let store = makeStore(
            projects: [
                Project(id: "p-2", name: "Two"),
                Project(id: "p-1", name: "One"),
                Project(id: "p-empty", name: "Empty"),
            ],
            workspaces: [
                workspace("w-a", "alpha", projectID: "p-2"),
                workspace("w-b", "beta", projectID: "p-1"),
            ]
        )

        let groups = store.groups
        XCTAssertEqual(groups.map(\.id), ["p-2", "p-1", "p-empty"])
        XCTAssertEqual(groups.map(\.name), ["Two", "One", "Empty"])
        XCTAssertEqual(groups.last?.workspaces, [], "an empty Project must render as an empty group, not be dropped")
    }

    /// A Workspace with no `projectID` buckets under its embedded `projectName`, keyed by the
    /// collision-proof embedded prefix and named after the embedded value.
    func testProjectLessWorkspaceBucketsUnderEmbeddedName() {
        let store = makeStore(
            projects: [],
            workspaces: [workspace("w-loose", "loose", projectID: nil, projectName: "Loose")]
        )

        let groups = store.groups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "__embedded:Loose")
        XCTAssertEqual(groups[0].name, "Loose")
        XCTAssertEqual(groups[0].workspaces.map(\.id), ["w-loose"])
    }

    /// A Workspace with neither a `projectID` nor an embedded `projectName` falls into the
    /// single ungrouped bucket, surfaced as "Other".
    func testBlankProjectNameFallsBackToOther() {
        let store = makeStore(
            projects: [],
            workspaces: [workspace("w-orphan", "orphan", projectID: nil, projectName: "")]
        )

        let groups = store.groups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "__ungrouped")
        XCTAssertEqual(groups[0].name, "Other")
        XCTAssertEqual(groups[0].workspaces.map(\.id), ["w-orphan"])
    }

    /// Rows within a group sort case-insensitively by name, independent of insertion order.
    func testRowsSortCaseInsensitivelyWithinGroup() {
        let store = makeStore(
            projects: [Project(id: "p", name: "P")],
            workspaces: [
                workspace("w-1", "banana", projectID: "p"),
                workspace("w-2", "Apple", projectID: "p"),
                workspace("w-3", "cherry", projectID: "p"),
            ]
        )

        let groups = store.groups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].workspaces.map(\.name), ["Apple", "banana", "cherry"])
    }
}
