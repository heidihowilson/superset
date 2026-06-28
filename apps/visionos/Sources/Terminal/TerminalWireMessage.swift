import Foundation

/// A control frame the relay/host sends down the terminal WebSocket as a **text** frame,
/// mirroring the web client's `TerminalServerMessage`
/// (`apps/web/.../WebTerminal/TerminalConnection.ts`). Binary frames are raw PTY output and
/// never reach this type — only the JSON text frames decode here.
enum TerminalControlMessage: Equatable, Sendable {
    /// The PTY was adopted/spawned and is streaming; carries the server's terminal id.
    case attached(terminalId: String)
    /// The remote set (or cleared) the window title.
    case title(String?)
    /// The PTY exited; carries its exit code and the signal that killed it (0 if none).
    case exit(exitCode: Int, signal: Int)
    /// The host reported a terminal-level error (provisioning/adoption failure).
    case error(message: String)
}

/// The terminal WebSocket wire protocol, hand-typed at the boundary (PRD §12) to match the
/// web client byte-for-byte: client→server frames are `{"type":"input"|"resize", …}` text,
/// server→client control frames are `{"type":"attached"|"title"|"exit"|"error", …}` text, and
/// PTY output rides as binary frames (decoded elsewhere). Pure value transforms with no
/// transport state, so the codec is unit-testable in isolation from any socket.
enum TerminalWireMessage {
    /// `{"type":"input","data":<keystrokes>}`. libghostty hands `send` raw encoded bytes; the
    /// wire carries them as a JSON string, matching the web (xterm's `onData` string). Decoded
    /// UTF-8 — terminal input is ASCII/UTF-8 in practice; an invalid sequence folds to U+FFFD
    /// rather than dropping the frame.
    static func encodeInput(_ bytes: Data) -> String {
        encodeInput(String(decoding: bytes, as: UTF8.self))
    }

    /// String overload — the same `{"type":"input","data":…}` frame from a ready-made string.
    static func encodeInput(_ data: String) -> String {
        encode(["type": "input", "data": data])
    }

    /// `{"type":"resize","cols":<cols>,"rows":<rows>}` — the grid changed; tell the PTY.
    static func encodeResize(cols: UInt16, rows: UInt16) -> String {
        encode(["type": "resize", "cols": Int(cols), "rows": Int(rows)])
    }

    /// Decode a server text frame into a `TerminalControlMessage`, or `nil` if it isn't a
    /// recognized control frame (unknown `type`, missing fields, or non-JSON). A best-effort
    /// read: an unrecognized frame is ignored, never fatal, so a newer host adding a frame
    /// type can't break an attached session.
    static func decodeControl(_ text: String) -> TerminalControlMessage? {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }

        switch type {
        case "attached":
            guard let terminalId = object["terminalId"] as? String else { return nil }
            return .attached(terminalId: terminalId)
        case "title":
            // `title` may be an explicit JSON null (title cleared) — decode that as nil.
            return .title(object["title"] as? String)
        case "exit":
            return .exit(
                exitCode: intValue(object["exitCode"]) ?? 0,
                signal: intValue(object["signal"]) ?? 0
            )
        case "error":
            guard let message = object["message"] as? String else { return nil }
            return .error(message: message)
        default:
            return nil
        }
    }

    /// Serialize an outbound frame as a compact, key-sorted JSON string. The dictionary only
    /// ever holds `String`/`Int` values, so `JSONSerialization` cannot realistically fail;
    /// `sortedKeys` keeps the output deterministic for tests.
    private static func encode(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    /// Coerce a JSON number that may arrive as `Int`, `Double`, or `NSNumber` into `Int`.
    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let double as Double: return Int(double)
        case let number as NSNumber: return number.intValue
        default: return nil
        }
    }
}
