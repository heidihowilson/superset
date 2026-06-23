import Foundation

/// A tolerant decode of arbitrary JSON the host-service emits inside chat content
/// parts (tool inputs/outputs whose shape varies per tool). The wire contract is
/// hand-typed at the boundary (PRD §12), but tool payloads are open-ended, so this
/// preserves whatever the Host sent without forcing a schema the loop can't pin
/// against a live, drifting server (§15). Renderers read the keys they understand
/// and fall back to a bounded flattened projection for the rest.
enum JSONValue: Sendable, Equatable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    /// The direct string payload when this value is a string (else nil) — the common
    /// case for a tool result that is plain text (shell output, file read).
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Look up a string field on an object value, e.g. a tool input's `command`.
    func string(_ key: String) -> String? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]?.stringValue
    }

    /// A bounded, human-readable flattening for the generic renderer: strings pass
    /// through, scalars stringify, and containers pretty-print so a structured tool
    /// result still shows *something* without a dedicated renderer. Capped so an
    /// oversized payload never floods the transcript (the "open full" host fetch,
    /// PRD §7.2, is a later affordance).
    func compactText(limit: Int = 4000) -> String {
        let rendered: String
        switch self {
        case let .string(value):
            rendered = value
        case let .number(value):
            rendered = Self.formatNumber(value)
        case let .bool(value):
            rendered = value ? "true" : "false"
        case .null:
            rendered = ""
        case .array, .object:
            rendered = prettyJSON(byteCap: limit * 8) ?? ""
        }
        return rendered.count > limit ? String(rendered.prefix(limit)) + "…" : rendered
    }

    /// Stringify a numeric value without trapping. `Int(Double)` traps for any value
    /// outside `Int` range (a byte count, epoch-nanos, or number-shaped hash past
    /// `Int.max` ≈ 9.2e18) and for non-finite input, so the integral fast-path is
    /// range-guarded; everything else formats through `String`/`%.0f`.
    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite, value == value.rounded() else { return String(value) }
        guard value.magnitude < 9e18 else { return String(format: "%.0f", value) }
        return String(Int(value))
    }

    /// Pretty-print, but cap the work: a multi-MB tool result would otherwise be
    /// materialized twice per paint (the encode round-trip plus the pretty-print)
    /// only for `compactText` to discard all but a bounded prefix. Past `byteCap`
    /// the compact encoding is truncated instead of pretty-printed.
    private func prettyJSON(byteCap: Int) -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        if data.count > byteCap {
            return String(decoding: data.prefix(byteCap), as: UTF8.self)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }
}

extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
