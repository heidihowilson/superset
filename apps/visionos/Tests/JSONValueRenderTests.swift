import XCTest
@testable import Superset

/// Coverage for the `JSONValue` generic renderer's number/oversize handling. The
/// pre-test review (#64) found `Int(Double)` traps the app on any integral `Double`
/// past `Int.max` (~9.2e18) emitted by host tool output — a byte count, epoch-nanos,
/// or number-shaped hash — when that transcript paints. These pin the range-guard and
/// the pretty-print cap so the renderer can never crash on unbounded numeric input.
final class JSONValueRenderTests: XCTestCase {
    /// The crash repro: an integral magnitude past `Int.max` must render (not trap).
    func testLargeWholeNumberDoesNotTrap() {
        XCTAssertEqual(JSONValue.number(1e19).compactText(), "10000000000000000000")
    }

    /// `-Int.max`-adjacent magnitudes are equally fatal to the `Int` cast.
    func testLargeNegativeWholeNumberDoesNotTrap() {
        XCTAssertEqual(JSONValue.number(-1e19).compactText(), "-10000000000000000000")
    }

    /// Non-finite input is integral under `value == value.rounded()` and also traps
    /// `Int(_:)`, so infinity must take the safe `String` path too.
    func testInfinityDoesNotTrap() {
        XCTAssertEqual(JSONValue.number(.infinity).compactText(), "inf")
        XCTAssertEqual(JSONValue.number(-.infinity).compactText(), "-inf")
    }

    /// In-range integral values keep the clean integer rendering (no `.0`, no exponent).
    func testInRangeWholeNumberRendersAsInteger() {
        XCTAssertEqual(JSONValue.number(42).compactText(), "42")
        XCTAssertEqual(JSONValue.number(-7).compactText(), "-7")
    }

    /// Fractional values still render through `String(Double)`.
    func testFractionalNumberRendersWithDecimal() {
        XCTAssertEqual(JSONValue.number(3.5).compactText(), "3.5")
    }

    /// An oversized container is truncated (with the ellipsis marker) rather than
    /// fully materialized — guards the pretty-print byte cap and the length cap.
    func testOversizedObjectIsTruncated() {
        let big = JSONValue.object(["blob": .string(String(repeating: "x", count: 50_000))])
        let rendered = big.compactText(limit: 4000)
        XCTAssertLessThanOrEqual(rendered.count, 4001) // limit + ellipsis
        XCTAssertTrue(rendered.hasSuffix("…"))
    }
}
