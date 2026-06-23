import XCTest
@testable import Superset

/// Coverage for the capped exponential poll backoff (#75): an asleep/offline host is the
/// normal case, so a failing poll must not keep retrying at the healthy interval. Each
/// consecutive failure doubles the wait up to the cap; one success snaps back to base.
final class PollBackoffTests: XCTestCase {
    func testHealthyPollsStayAtBaseInterval() {
        var backoff = PollBackoff(base: .seconds(7), maxInterval: .seconds(60))
        XCTAssertEqual(backoff.currentInterval, .seconds(7))

        backoff.record(success: true)
        XCTAssertEqual(backoff.currentInterval, .seconds(7), "a healthy poll keeps the fast interval")
    }

    func testConsecutiveFailuresDoubleTheInterval() {
        var backoff = PollBackoff(base: .seconds(2), maxInterval: .seconds(60))

        backoff.record(success: false) // 1st failure
        XCTAssertEqual(backoff.currentInterval, .seconds(2))
        backoff.record(success: false) // 2nd
        XCTAssertEqual(backoff.currentInterval, .seconds(4))
        backoff.record(success: false) // 3rd
        XCTAssertEqual(backoff.currentInterval, .seconds(8))
        backoff.record(success: false) // 4th
        XCTAssertEqual(backoff.currentInterval, .seconds(16))
    }

    func testIntervalIsClampedToTheCap() {
        var backoff = PollBackoff(base: .seconds(7), maxInterval: .seconds(60))
        for _ in 0 ..< 20 { backoff.record(success: false) }
        XCTAssertEqual(backoff.currentInterval, .seconds(60), "the doubling never exceeds the cap")
    }

    func testSuccessResetsToBase() {
        var backoff = PollBackoff(base: .seconds(2), maxInterval: .seconds(30))
        for _ in 0 ..< 5 { backoff.record(success: false) }
        XCTAssertGreaterThan(backoff.currentInterval, .seconds(2))

        backoff.record(success: true)
        XCTAssertEqual(backoff.currentInterval, .seconds(2), "recovery is detected at the fast interval, no lag")
    }

    func testCapIsNeverBelowBase() {
        // A misconfigured cap below base must not produce an interval shorter than base.
        let backoff = PollBackoff(base: .seconds(7), maxInterval: .seconds(1))
        XCTAssertEqual(backoff.currentInterval, .seconds(7))
    }
}
