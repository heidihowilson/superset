import XCTest
@testable import Superset

/// `ChatDisplayState.init(from:)` (#93) folds two sources into one `isAwaitingDecision`
/// flag — a live host `pendingApproval` object *or* a cached derived bool — trims a blank
/// `errorMessage` to nil, and defaults `isRunning` to false when absent. The watch poll
/// must degrade, never blank, on contract drift (PRD §15), so each branch is pinned here.
final class ChatDisplayStateDecodeTests: XCTestCase {
    private func decodeState(_ json: String) throws -> ChatDisplayState {
        try JSONDecoder().decode(ChatDisplayState.self, from: Data(json.utf8))
    }

    /// A live host snapshot carrying a `pendingApproval` object marks the turn as awaiting a
    /// decision, even though the cached `isAwaitingDecision` flag is absent.
    func testPendingApprovalObjectSetsAwaitingDecision() throws {
        let state = try decodeState(#"{"isRunning":true,"pendingApproval":{"toolCallId":"call-1"}}"#)
        XCTAssertTrue(state.isAwaitingDecision)
        XCTAssertTrue(state.isRunning)
    }

    /// A re-painted cache has no `pendingApproval` object but carries the derived
    /// `isAwaitingDecision` bool — that alone marks the turn as awaiting a decision.
    func testCachedFlagSetsAwaitingDecisionWithoutPendingApproval() throws {
        let state = try decodeState(#"{"isRunning":false,"isAwaitingDecision":true}"#)
        XCTAssertTrue(state.isAwaitingDecision)
    }

    /// Neither source present → not awaiting a decision.
    func testNoApprovalSourceLeavesAwaitingDecisionFalse() throws {
        let state = try decodeState(#"{"isRunning":true}"#)
        XCTAssertFalse(state.isAwaitingDecision)
    }

    /// A whitespace-only `errorMessage` normalizes to nil rather than surfacing a blank error.
    func testWhitespaceErrorMessageNormalizesToNil() throws {
        let state = try decodeState(#"{"isRunning":false,"errorMessage":"   \n  "}"#)
        XCTAssertNil(state.errorMessage)
    }

    /// A non-blank `errorMessage` is preserved, trimmed of surrounding whitespace.
    func testNonBlankErrorMessageIsTrimmedAndKept() throws {
        let state = try decodeState(#"{"isRunning":false,"errorMessage":"  boom  "}"#)
        XCTAssertEqual(state.errorMessage, "boom")
    }

    /// An absent `isRunning` defaults to false — a missing flag must decode, never throw.
    func testMissingIsRunningDefaultsToFalse() throws {
        let state = try decodeState(#"{"errorMessage":"x"}"#)
        XCTAssertFalse(state.isRunning)
    }

    /// Encode/decode round-trip preserves the derived `isAwaitingDecision` flag: the encoder
    /// writes the bool (not the host `pendingApproval` object), so a cached re-decode recovers it.
    func testRoundTripPreservesDerivedAwaitingDecisionFlag() throws {
        let original = try decodeState(#"{"isRunning":true,"errorMessage":"fail","pendingApproval":{"toolCallId":"c"}}"#)
        XCTAssertTrue(original.isAwaitingDecision)

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ChatDisplayState.self, from: data)

        XCTAssertEqual(restored.isRunning, original.isRunning)
        XCTAssertEqual(restored.errorMessage, original.errorMessage)
        XCTAssertTrue(restored.isAwaitingDecision)
        XCTAssertEqual(restored, original)
    }
}
