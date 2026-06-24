import XCTest
@testable import Superset

/// Pins the `WorkspaceStatus.allowsHostActions` truth table (issue #100). The property is the
/// single source of truth for whether a host-gated action (create/delete, live host calls) may
/// be attempted, so its per-case value is a contract — a future enum case must force an explicit
/// true/false decision rather than silently inheriting an eligibility. Iterating `allCases` here
/// means adding a case fails the switch in this test until the case is classified below.
final class WorkspaceStatusHostActionsTests: XCTestCase {
    /// The documented eligible set: the Host is reachable on a plan (`.hostOnline`) or a
    /// Host-gated run state that only lands while it is (`.running`/`.idle`).
    private func expectedAllowsHostActions(for status: WorkspaceStatus) -> Bool {
        switch status {
        case .hostOnline, .running, .idle:
            return true
        case .hostAsleep, .planGated, .unknown:
            return false
        }
    }

    /// Every case must match the documented set, and the set must stay exhaustive — a new case
    /// breaks `expectedAllowsHostActions`, forcing the decision instead of defaulting it.
    func testAllowsHostActionsMatchesDocumentedSet() {
        for status in WorkspaceStatus.allCases {
            XCTAssertEqual(
                status.allowsHostActions,
                expectedAllowsHostActions(for: status),
                "\(status) allowsHostActions diverged from the documented truth table"
            )
        }
    }

    /// Spell out the eligible cases directly so the expected truth table isn't only asserted
    /// against a copy of itself.
    func testEligibleStatusesAllowHostActions() {
        XCTAssertTrue(WorkspaceStatus.hostOnline.allowsHostActions)
        XCTAssertTrue(WorkspaceStatus.running.allowsHostActions)
        XCTAssertTrue(WorkspaceStatus.idle.allowsHostActions)
    }

    /// Spell out the refused cases directly: the client already knows these will 403, so it must
    /// not dial the relay.
    func testIneligibleStatusesRefuseHostActions() {
        XCTAssertFalse(WorkspaceStatus.hostAsleep.allowsHostActions)
        XCTAssertFalse(WorkspaceStatus.planGated.allowsHostActions)
        XCTAssertFalse(WorkspaceStatus.unknown.allowsHostActions)
    }

    /// Guards the iterating test above: if `allCases` ever shrinks, the matrix test could pass
    /// vacuously, so pin the count to the six documented cases.
    func testAllCasesCoversEveryStatus() {
        XCTAssertEqual(WorkspaceStatus.allCases.count, 6)
    }
}
