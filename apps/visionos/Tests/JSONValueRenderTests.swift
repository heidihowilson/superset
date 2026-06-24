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

    // MARK: - Decode

    /// A mixed object exercises every scalar branch of `init(from:)` plus the nested
    /// array/object recursion; the integer field must land as `.number` (not `.bool`),
    /// pinning the bool-before-number decode order.
    func testMixedJSONDecodesEveryBranch() throws {
        let json = """
        {"name":"build","ok":true,"count":3,"ratio":1.5,"empty":null,\
        "args":["a","b"],"meta":{"k":"v"}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value, .object([
            "name": .string("build"),
            "ok": .bool(true),
            "count": .number(3),
            "ratio": .number(1.5),
            "empty": .null,
            "args": .array([.string("a"), .string("b")]),
            "meta": .object(["k": .string("v")]),
        ]))
    }

    /// A top-level array decodes its scalar elements (and covers the array branch as root).
    func testTopLevelArrayDecodes() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("[true,1,\"x\",null]".utf8))
        XCTAssertEqual(value, .array([.bool(true), .number(1), .string("x"), .null]))
    }

    /// Encoding then decoding a nested mixed value yields an equal value (lossless round-trip).
    func testNestedMixedJSONRoundTrips() throws {
        let original = JSONValue.object([
            "tool": .string("shell"),
            "input": .object(["command": .string("ls"), "retry": .bool(false)]),
            "outputs": .array([.number(0), .string("done")]),
        ])
        let reencoded = try JSONEncoder().encode(original)
        let redecoded = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        XCTAssertEqual(redecoded, original)
    }

    // MARK: - stringValue

    /// The direct payload of a string value (the plain-text tool result case).
    func testStringValueReturnsPayloadForString() {
        XCTAssertEqual(JSONValue.string("shell output").stringValue, "shell output")
    }

    /// Every non-string case yields nil rather than a stringified projection.
    func testStringValueNilForNonString() {
        XCTAssertNil(JSONValue.number(1).stringValue)
        XCTAssertNil(JSONValue.bool(true).stringValue)
        XCTAssertNil(JSONValue.null.stringValue)
        XCTAssertNil(JSONValue.array([.string("x")]).stringValue)
        XCTAssertNil(JSONValue.object(["k": .string("v")]).stringValue)
    }

    // MARK: - string(_:)

    /// Looking up a string field on an object returns its payload (e.g. a tool input's `command`).
    func testStringKeyReadsObjectStringField() {
        let object = JSONValue.object(["command": .string("ls -la"), "code": .number(0)])
        XCTAssertEqual(object.string("command"), "ls -la")
    }

    /// A missing key, or a present-but-non-string field, both yield nil.
    func testStringKeyNilForMissingOrNonStringField() {
        let object = JSONValue.object(["code": .number(0)])
        XCTAssertNil(object.string("command")) // missing key
        XCTAssertNil(object.string("code")) // present but not a string
    }

    /// A non-object receiver never resolves a key.
    func testStringKeyNilForNonObject() {
        XCTAssertNil(JSONValue.string("plain").string("anything"))
        XCTAssertNil(JSONValue.array([.string("x")]).string("0"))
        XCTAssertNil(JSONValue.null.string("k"))
    }
}
