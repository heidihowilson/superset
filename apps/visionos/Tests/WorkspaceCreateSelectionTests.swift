import XCTest
@testable import Superset

/// Coverage for the create sheet's picker-seeding rule (issue #68). The sheet often opens
/// before the first poll lands, so the Project/Host selection must follow the data as the
/// lists arrive and must not dangle when a later poll deletes the selected item.
final class WorkspaceCreateSelectionTests: XCTestCase {
    /// Sheet opened before data: nil selection + empty list stays nil (nothing to pick yet).
    func testNilSelectionEmptyListStaysNil() {
        XCTAssertNil(WorkspaceCreateView.resolveSelection(current: nil, available: []))
    }

    /// Data arrives after `onAppear`: a nil selection seeds to the first available id, so
    /// Create can enable instead of staying greyed with nothing selected.
    func testNilSelectionSeedsToFirstWhenListArrives() {
        XCTAssertEqual(
            WorkspaceCreateView.resolveSelection(current: nil, available: ["a", "b"]),
            "a"
        )
    }

    /// A still-valid selection is preserved when the list refreshes (no surprise reset).
    func testPresentSelectionIsKept() {
        XCTAssertEqual(
            WorkspaceCreateView.resolveSelection(current: "b", available: ["a", "b"]),
            "b"
        )
    }

    /// The selected item was deleted by a later poll: re-seed to the first survivor rather
    /// than leave a dangling id that `submit()` would dial.
    func testDeletedSelectionReseedsToFirst() {
        XCTAssertEqual(
            WorkspaceCreateView.resolveSelection(current: "gone", available: ["a", "b"]),
            "a"
        )
    }

    /// Every item disappeared: the selection clears to nil (Create gates off).
    func testSelectionClearsWhenListEmpties() {
        XCTAssertNil(WorkspaceCreateView.resolveSelection(current: "a", available: []))
    }
}
