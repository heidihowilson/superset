import Foundation

/// One watch observation of a Workspace's agent Chat session — the result of a
/// single `chat.getSnapshot` poll over the relay (host-service, PRD §6.3/§7.2).
/// `getSnapshot` returns display state and messages from one runtime acquisition,
/// so the client avoids the dual-poll race between `getDisplayState`/`listMessages`.
///
/// `Codable` so the last good transcript can be cached and re-painted instantly on
/// the next open — the cache-first rule that keeps a backgrounding cycle from
/// blanking shown data (ADR-0004, the M0c gate).
struct ChatTranscript: Sendable, Equatable, Codable {
    var displayState: ChatDisplayState
    var messages: [ChatMessage]

    static let empty = ChatTranscript(displayState: .idle, messages: [])

    var isEmpty: Bool { messages.isEmpty }
}

/// The watch-relevant slice of the host-service `ChatDisplayState`. Hand-typed to the
/// few fields the ambient/lean-in transcript needs (PRD §12); the harness state is
/// far larger, but the rest (pending questions, plan approvals) belongs to the
/// Prompt milestone (#5), not Watch.
struct ChatDisplayState: Sendable, Equatable, Codable {
    /// Whether a turn is in flight — drives the ambient "thinking" status.
    var isRunning: Bool
    /// A surfaced run error, if the last/active turn failed.
    var errorMessage: String?

    static let idle = ChatDisplayState(isRunning: false, errorMessage: nil)

    private enum CodingKeys: String, CodingKey {
        case isRunning
        case errorMessage
    }

    init(isRunning: Bool, errorMessage: String?) {
        self.isRunning = isRunning
        self.errorMessage = errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isRunning = ((try? container.decodeIfPresent(Bool.self, forKey: .isRunning)) ?? nil) ?? false
        let raw = (try? container.decodeIfPresent(String.self, forKey: .errorMessage)) ?? nil
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// Who authored a message. Unknown roles decode to `.other` rather than failing the
/// poll — server-contract drift must degrade, never blank (PRD §15).
enum ChatRole: String, Sendable, Equatable, Codable {
    case user
    case assistant
    case system
    case other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChatRole(rawValue: raw) ?? .other
    }
}

/// A single message in the host-service transcript. The host returns Mastra-format
/// messages whose ordered parts live under `content` (not the AI-SDK `parts` the
/// desktop's UI layer later maps to) — see the desktop's `getSnapshot` consumer.
struct ChatMessage: Sendable, Equatable, Codable, Identifiable {
    let id: String
    var role: ChatRole
    var content: [ChatMessagePart]

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
    }

    init(id: String, role: ChatRole, content: [ChatMessagePart]) {
        self.id = id
        self.role = role
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The Host keys message ids off the memory store; tolerate an absent id by
        // synthesizing a stable-enough fallback so SwiftUI identity still holds.
        if let decoded = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil {
            id = decoded
        } else {
            id = UUID().uuidString
        }
        role = (try? container.decode(ChatRole.self, forKey: .role)) ?? .other
        content = ((try? container.decodeIfPresent([ChatMessagePart].self, forKey: .content)) ?? nil) ?? []
    }
}

/// One ordered part of a message. The host-service content stream mixes assistant
/// prose, thinking, tool calls/results, and attachments; this is the bounded set the
/// V1 transcript routes to renderers, with `.other` as the generic fallback for
/// part types a renderer doesn't special-case yet (PRD §7.2).
enum ChatMessagePart: Sendable, Equatable, Codable {
    /// Streaming markdown prose — rendered in the WKWebView content surface (ADR-0009).
    case text(String)
    /// Agent reasoning ("thinking") — collapsible, native (PRD §9 lean-in).
    case reasoning(String)
    /// A tool invocation or its result, projected for the bounded inline renderers.
    case tool(ChatToolPart)
    /// An image/file attachment reference — shown as a chip, not inlined in V1.
    case attachment(name: String?, mediaType: String?)
    /// Any other part type, preserved by name so the generic fallback can label it.
    case other(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case reasoning
        case name
        case toolName
        case id
        case toolCallId
        case input
        case arguments
        case args
        case output
        case result
        case filename
        case mediaType
        case mimeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? "unknown"

        switch type {
        case "text":
            self = .text((try? container.decode(String.self, forKey: .text)) ?? "")
        case "thinking", "reasoning":
            let value = (try? container.decode(String.self, forKey: .thinking))
                ?? (try? container.decode(String.self, forKey: .reasoning))
                ?? (try? container.decode(String.self, forKey: .text))
                ?? ""
            self = .reasoning(value)
        case "image", "file":
            let name = try? container.decode(String.self, forKey: .filename)
            let media = (try? container.decode(String.self, forKey: .mediaType))
                ?? (try? container.decode(String.self, forKey: .mimeType))
            self = .attachment(name: name, mediaType: media)
        default:
            // Tool calls/results carry a name; treat anything name-bearing as a tool
            // part so the inline renderers can show it. Genuinely unknown parts keep
            // their type for the generic label.
            let name = (try? container.decode(String.self, forKey: .toolName))
                ?? (try? container.decode(String.self, forKey: .name))
            if let name {
                let isResult = type.contains("result")
                var payload: JSONValue?
                for key in [CodingKeys.output, .result, .input, .arguments, .args] {
                    if let value = try? container.decode(JSONValue.self, forKey: key) {
                        payload = value
                        break
                    }
                }
                self = .tool(ChatToolPart(name: name, isResult: isResult, payload: payload))
            } else {
                self = .other(type: type)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case let .reasoning(value):
            try container.encode("thinking", forKey: .type)
            try container.encode(value, forKey: .thinking)
        case let .tool(part):
            try container.encode(part.isResult ? "tool_result" : "tool_call", forKey: .type)
            try container.encode(part.name, forKey: .name)
            try container.encodeIfPresent(part.payload, forKey: .output)
        case let .attachment(name, mediaType):
            try container.encode("file", forKey: .type)
            try container.encodeIfPresent(name, forKey: .filename)
            try container.encodeIfPresent(mediaType, forKey: .mediaType)
        case let .other(type):
            try container.encode(type, forKey: .type)
        }
    }
}

/// A tool call or result, projected to what the inline renderers display: the tool's
/// name and a tolerant payload (input for a call, output for a result). The bounded
/// per-tool renderers (diff/file/shell/search/web — PRD §7.2) build on this; V1 ships
/// the generic projection (`payload.compactText()`) as the fallback.
struct ChatToolPart: Sendable, Equatable, Codable {
    var name: String
    /// True for a tool *result* part, false for the invocation.
    var isResult: Bool
    var payload: JSONValue?
}
