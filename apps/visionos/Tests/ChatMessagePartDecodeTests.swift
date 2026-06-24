import XCTest
@testable import Superset

/// `ChatMessagePart.init(from:)` (#92) maps a drifting host wire format onto a bounded enum:
/// text/thinking/reasoning/image/file plus the name-bearing-default → `.tool` fallback and the
/// payload key-priority loop, with `.other` for genuinely unknown types. Server-contract drift
/// must degrade, never blank (PRD §15), so each branch is pinned here.
final class ChatMessagePartDecodeTests: XCTestCase {
    private func decodePart(_ json: String) throws -> ChatMessagePart {
        try JSONDecoder().decode(ChatMessagePart.self, from: Data(json.utf8))
    }

    /// A `text` part decodes to `.text` carrying the `text` field.
    func testTextPart() throws {
        let part = try decodePart(#"{"type":"text","text":"hello world"}"#)
        XCTAssertEqual(part, .text("hello world"))
    }

    /// A `thinking` part reads its prose from the `thinking` key and decodes to `.reasoning`.
    func testThinkingPart() throws {
        let part = try decodePart(#"{"type":"thinking","thinking":"weighing options"}"#)
        XCTAssertEqual(part, .reasoning("weighing options"))
    }

    /// The `reasoning` type alias also decodes to `.reasoning`, reading its `reasoning` key —
    /// the host uses either name for the same agent-thinking part.
    func testReasoningAliasPart() throws {
        let part = try decodePart(#"{"type":"reasoning","reasoning":"because X"}"#)
        XCTAssertEqual(part, .reasoning("because X"))
    }

    /// A reasoning-type part whose prose arrives under the `text` key still decodes — the value
    /// lookup falls through `thinking` → `reasoning` → `text`.
    func testThinkingFallsBackToTextKey() throws {
        let part = try decodePart(#"{"type":"thinking","text":"fallback prose"}"#)
        XCTAssertEqual(part, .reasoning("fallback prose"))
    }

    /// A `file` part decodes to `.attachment`, carrying `filename` and `mediaType`.
    func testFilePartWithMediaType() throws {
        let part = try decodePart(#"{"type":"file","filename":"report.pdf","mediaType":"application/pdf"}"#)
        XCTAssertEqual(part, .attachment(name: "report.pdf", mediaType: "application/pdf"))
    }

    /// An `image` part with the `mimeType` alias decodes to `.attachment` with that media type —
    /// `mediaType` and `mimeType` name the same field across host versions.
    func testImagePartWithMimeTypeAlias() throws {
        let part = try decodePart(#"{"type":"image","filename":"shot.png","mimeType":"image/png"}"#)
        XCTAssertEqual(part, .attachment(name: "shot.png", mediaType: "image/png"))
    }

    /// A `tool_result` decodes to `.tool` with `isResult == true`, its payload taken from
    /// `output` (highest-priority result key).
    func testToolResultCarryingOutput() throws {
        let part = try decodePart(#"{"type":"tool_result","toolName":"bash","output":"command finished"}"#)
        guard case let .tool(toolPart) = part else {
            return XCTFail("expected .tool, got \(part)")
        }
        XCTAssertEqual(toolPart.name, "bash")
        XCTAssertTrue(toolPart.isResult)
        XCTAssertEqual(toolPart.payload?.stringValue, "command finished")
    }

    /// A `tool_call` decodes to `.tool` with `isResult == false`, its payload taken from
    /// `input`, and object fields are reachable via `JSONValue.string(_:)`.
    func testToolCallCarryingInput() throws {
        let part = try decodePart(#"{"type":"tool_call","name":"editor","input":{"command":"write"}}"#)
        guard case let .tool(toolPart) = part else {
            return XCTFail("expected .tool, got \(part)")
        }
        XCTAssertEqual(toolPart.name, "editor")
        XCTAssertFalse(toolPart.isResult)
        XCTAssertEqual(toolPart.payload?.string("command"), "write")
    }

    /// A `tool_call` carrying a stray `output` alongside its `input` still projects the `input` —
    /// the key precedence branches on the part kind, so a call never surfaces a result payload in
    /// the invocation slot of the inline card.
    func testToolCallPrefersInputOverStrayOutput() throws {
        let part = try decodePart(
            #"{"type":"tool_call","name":"editor","input":{"command":"write"},"output":"stray result"}"#
        )
        guard case let .tool(toolPart) = part else {
            return XCTFail("expected .tool, got \(part)")
        }
        XCTAssertFalse(toolPart.isResult)
        XCTAssertEqual(toolPart.payload?.string("command"), "write")
    }

    /// A `tool_result` carrying both `output` and `input` still projects the `output` — results
    /// keep output-first precedence, so a stray input field can't displace the result text.
    func testToolResultPrefersOutputOverStrayInput() throws {
        let part = try decodePart(
            #"{"type":"tool_result","toolName":"bash","input":{"command":"ls"},"output":"command finished"}"#
        )
        guard case let .tool(toolPart) = part else {
            return XCTFail("expected .tool, got \(part)")
        }
        XCTAssertTrue(toolPart.isResult)
        XCTAssertEqual(toolPart.payload?.stringValue, "command finished")
    }

    /// An unknown type with no tool name decodes to `.other`, preserving the type for the
    /// generic label rather than failing the poll.
    func testUnknownTypeDecodesToOther() throws {
        let part = try decodePart(#"{"type":"mystery"}"#)
        XCTAssertEqual(part, .other(type: "mystery"))
    }

    /// A part missing `type` entirely is treated as `unknown` and lands in `.other` — an absent
    /// discriminator must still decode, never throw.
    func testMissingTypeDecodesToOther() throws {
        let part = try decodePart(#"{"text":"orphan"}"#)
        XCTAssertEqual(part, .other(type: "unknown"))
    }
}
