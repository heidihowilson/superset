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

    private enum CodingKeys: String, CodingKey {
        case displayState
        case messages
    }

    init(displayState: ChatDisplayState, messages: [ChatMessage]) {
        self.displayState = displayState
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayState = ((try? container.decodeIfPresent(ChatDisplayState.self, forKey: .displayState)) ?? nil) ?? .idle
        let decoded = ((try? container.decodeIfPresent([ChatMessage].self, forKey: .messages)) ?? nil) ?? []
        // Fold transcript position into the ids the decoder synthesized for id-less
        // messages, so structurally identical ones stay distinct. Host-id'd messages are
        // untouched.
        messages = decoded.enumerated().map { index, message in
            message.disambiguatedFallbackID(at: index)
        }
    }
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
    /// True when the agent is blocked on a user approve/reject decision — the host's
    /// `pendingApproval` (a tool awaiting permission). Gates the composer's one-tap
    /// quick-action chips, which only apply while such a decision is pending (PRD §9).
    var isAwaitingDecision: Bool

    static let idle = ChatDisplayState(isRunning: false, errorMessage: nil)

    private enum CodingKeys: String, CodingKey {
        case isRunning
        case errorMessage
        case pendingApproval
        case isAwaitingDecision
    }

    /// The few `pendingApproval` fields needed to detect presence; a non-null object
    /// means a tool is awaiting the user's decision. Decoded tolerantly — its mere
    /// presence is the signal, not any particular field.
    private struct PendingApprovalProbe: Decodable {
        let toolCallId: String?
    }

    init(isRunning: Bool, errorMessage: String?, isAwaitingDecision: Bool = false) {
        self.isRunning = isRunning
        self.errorMessage = errorMessage
        self.isAwaitingDecision = isAwaitingDecision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isRunning = ((try? container.decodeIfPresent(Bool.self, forKey: .isRunning)) ?? nil) ?? false
        let raw = (try? container.decodeIfPresent(String.self, forKey: .errorMessage)) ?? nil
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = (trimmed?.isEmpty == false) ? trimmed : nil
        // The host snapshot carries `pendingApproval`; a re-painted cache carries the
        // derived flag. Either source marks the turn as awaiting a decision.
        let approval = (try? container.decodeIfPresent(PendingApprovalProbe.self, forKey: .pendingApproval)) ?? nil
        let cached = ((try? container.decodeIfPresent(Bool.self, forKey: .isAwaitingDecision)) ?? nil) ?? false
        isAwaitingDecision = approval != nil || cached
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isRunning, forKey: .isRunning)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(isAwaitingDecision, forKey: .isAwaitingDecision)
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
    /// False when `id` was derived from content because the host sent none. The transcript
    /// folds in list position for these (and only these) so two structurally identical
    /// id-less messages keep distinct SwiftUI identities — see `disambiguatedFallbackID`.
    /// Not part of message identity, so it is excluded from `Equatable`.
    let hasHostID: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
    }

    init(id: String, role: ChatRole, content: [ChatMessagePart]) {
        self.init(id: id, role: role, content: content, hasHostID: true)
    }

    private init(id: String, role: ChatRole, content: [ChatMessagePart], hasHostID: Bool) {
        self.id = id
        self.role = role
        self.content = content
        self.hasHostID = hasHostID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? container.decode(ChatRole.self, forKey: .role)) ?? .other
        content = ((try? container.decodeIfPresent([ChatMessagePart].self, forKey: .content)) ?? nil) ?? []
        // The Host keys message ids off the memory store; tolerate an absent id by
        // deriving a deterministic id from the content so SwiftUI identity holds steady
        // across the 2s poll. A fresh `UUID()` per decode changed the row's identity every
        // tick — teardown/rebuild, lost scroll, flicker.
        if let decoded = ((try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil),
           !decoded.isEmpty {
            id = decoded
            hasHostID = true
        } else {
            id = Self.derivedID(role: role, content: content)
            hasHostID = false
        }
    }

    /// Total prose length across the message's parts — grows as a streaming message
    /// extends in place (same id), so the transcript can auto-scroll on growth, not just
    /// when a new id lands.
    var contentLength: Int { content.reduce(0) { $0 + $1.textLength } }

    /// For a message whose id was derived from content (the host sent none), fold its
    /// transcript position into the id so two structurally identical id-less messages keep
    /// distinct identities. Host-id'd messages are returned unchanged.
    func disambiguatedFallbackID(at index: Int) -> ChatMessage {
        guard !hasHostID else { return self }
        return ChatMessage(id: "\(id)-\(index)", role: role, content: content, hasHostID: false)
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.role == rhs.role && lhs.content == rhs.content
    }

    /// Deterministic id for an id-less message: a stable hash of role + ordered content.
    /// Stable across re-decodes (same content → same id), unlike `UUID()`.
    private static func derivedID(role: ChatRole, content: [ChatMessagePart]) -> String {
        var canonical = role.rawValue
        for part in content {
            canonical += "\u{1f}\(part.identitySignature)"
        }
        return "synthetic-\(stableHash(canonical))"
    }

    /// FNV-1a (64-bit), deterministic across process launches — unlike `Hasher`, whose
    /// per-launch seed would change a re-decoded message's id and reintroduce the flicker.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
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
                // Project the payload that matches the part kind: a result prefers its
                // output, a call prefers its input. A stray output on a call part (or input
                // on a result) must not win, or the inline card shows the wrong text.
                let payloadKeys: [CodingKeys] = isResult
                    ? [.output, .result, .input, .arguments, .args]
                    : [.input, .arguments, .args, .output, .result]
                var payload: JSONValue?
                for key in payloadKeys {
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

    /// Character count of prose this part carries (text or reasoning); tool/attachment/
    /// other parts contribute 0. Summed per message to detect in-place streaming growth.
    var textLength: Int {
        switch self {
        case let .text(value), let .reasoning(value): value.count
        case .tool, .attachment, .other: 0
        }
    }

    /// A stable per-part string used to derive an id-less message's identity. Captures the
    /// part's kind and salient content so a re-decode of the same message yields the same id.
    var identitySignature: String {
        switch self {
        case let .text(value): "t:\(value)"
        case let .reasoning(value): "r:\(value)"
        case let .tool(part): "tool:\(part.name):\(part.isResult)"
        case let .attachment(name, mediaType): "att:\(name ?? ""):\(mediaType ?? "")"
        case let .other(type): "other:\(type)"
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
