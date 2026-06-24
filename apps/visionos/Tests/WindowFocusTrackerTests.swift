import XCTest
@testable import Superset

/// Coverage for the M3 dwell flush (#105). A window closed while active fires `onDisappear`
/// with no preceding inactive transition; the tracker must still record that open interval
/// exactly once so the foreground dwell isn't silently dropped — and never double-count it
/// when both the inactive boundary and the trailing disappear flush.
@MainActor
final class WindowFocusTrackerTests: XCTestCase {
    /// The headline case: begin (window active) then flush (closed while active, no inactive
    /// transition) records the dwell once, for the right window kind.
    func testFlushRecordsOpenIntervalOnDisappearWhileActive() {
        var tracker = WindowFocusTracker(kind: "workspace")
        var calls: [(kind: String, seconds: Double)] = []

        tracker.begin()
        tracker.flush { calls.append((kind: $0, seconds: $1)) }

        XCTAssertEqual(calls.count, 1, "an open dwell flushes exactly once")
        XCTAssertEqual(calls.first?.kind, "workspace")
        XCTAssertGreaterThanOrEqual(calls.first?.seconds ?? -1, 0)
    }

    /// Idempotent: once the inactive boundary has flushed, the trailing disappear flush (or
    /// any second flush) records nothing — no double-counting.
    func testSecondFlushIsNoOp() {
        var tracker = WindowFocusTracker(kind: "workspace")
        var count = 0

        tracker.begin()
        tracker.flush { _, _ in count += 1 }
        tracker.flush { _, _ in count += 1 }

        XCTAssertEqual(count, 1, "the cleared interval is not recorded a second time")
    }

    /// Flushing with no open interval (disappear while already inactive) does nothing.
    func testFlushWithoutBeginIsNoOp() {
        var tracker = WindowFocusTracker(kind: "workspace")
        var count = 0

        tracker.flush { _, _ in count += 1 }

        XCTAssertEqual(count, 0, "no open interval means nothing to record")
    }
}
