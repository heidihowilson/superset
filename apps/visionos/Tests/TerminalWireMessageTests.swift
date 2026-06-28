import XCTest
@testable import Superset

/// Codec coverage for the terminal WebSocket wire protocol (`TerminalWireMessage`): the
/// outbound `input`/`resize` frames the surface produces and the inbound control frames the
/// host sends. The wire shape must stay byte-compatible with the web client
/// (`apps/web/.../WebTerminal/TerminalConnection.ts`), so a drift in the JSON keys or the
/// decode tolerance can't ship silently.
final class TerminalWireMessageTests: XCTestCase {
    // MARK: Encode

    func testEncodeInputFromDataWrapsKeystrokesAsInputFrame() throws {
        let frame = TerminalWireMessage.encodeInput(Data("ls -la\n".utf8))
        let json = try object(frame)
        XCTAssertEqual(json["type"] as? String, "input")
        XCTAssertEqual(json["data"] as? String, "ls -la\n")
    }

    func testEncodeInputPreservesControlBytesAndEscapesJSON() throws {
        // A Ctrl-C (0x03) plus a quote must survive JSON encoding intact.
        let frame = TerminalWireMessage.encodeInput(Data([0x03]) + Data("\"x\"".utf8))
        let json = try object(frame)
        XCTAssertEqual(json["data"] as? String, "\u{03}\"x\"")
    }

    func testEncodeResizeCarriesColsAndRowsAsNumbers() throws {
        let frame = TerminalWireMessage.encodeResize(cols: 120, rows: 40)
        let json = try object(frame)
        XCTAssertEqual(json["type"] as? String, "resize")
        XCTAssertEqual(json["cols"] as? Int, 120)
        XCTAssertEqual(json["rows"] as? Int, 40)
    }

    // MARK: Decode

    func testDecodeAttachedReadsTerminalId() {
        let message = TerminalWireMessage.decodeControl(#"{"type":"attached","terminalId":"term-7"}"#)
        XCTAssertEqual(message, .attached(terminalId: "term-7"))
    }

    func testDecodeTitleReadsStringAndNull() {
        XCTAssertEqual(
            TerminalWireMessage.decodeControl(#"{"type":"title","title":"~/repo"}"#),
            .title("~/repo")
        )
        // An explicit null title (the remote cleared it) decodes to `.title(nil)`.
        XCTAssertEqual(
            TerminalWireMessage.decodeControl(#"{"type":"title","title":null}"#),
            .title(nil)
        )
    }

    func testDecodeExitReadsCodeAndSignal() {
        XCTAssertEqual(
            TerminalWireMessage.decodeControl(#"{"type":"exit","exitCode":137,"signal":9}"#),
            .exit(exitCode: 137, signal: 9)
        )
    }

    func testDecodeExitDefaultsMissingFieldsToZero() {
        XCTAssertEqual(
            TerminalWireMessage.decodeControl(#"{"type":"exit"}"#),
            .exit(exitCode: 0, signal: 0)
        )
    }

    func testDecodeErrorReadsMessage() {
        XCTAssertEqual(
            TerminalWireMessage.decodeControl(#"{"type":"error","message":"host offline"}"#),
            .error(message: "host offline")
        )
    }

    func testDecodeRejectsUnknownTypeAndMalformedFrames() {
        XCTAssertNil(TerminalWireMessage.decodeControl(#"{"type":"heartbeat"}"#))
        XCTAssertNil(TerminalWireMessage.decodeControl("not json"))
        // `attached` without a terminalId isn't a usable control frame.
        XCTAssertNil(TerminalWireMessage.decodeControl(#"{"type":"attached"}"#))
        // `error` without a message likewise.
        XCTAssertNil(TerminalWireMessage.decodeControl(#"{"type":"error"}"#))
    }

    private func object(_ frame: String) throws -> [String: Any] {
        let data = try XCTUnwrap(frame.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
