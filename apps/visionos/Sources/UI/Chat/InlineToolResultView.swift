import SwiftUI

/// Native inline renderer for a tool call/result part (PRD §7.2). V1 ships a single
/// bounded, generic card: an icon + label keyed off the tool name (the bounded set —
/// shell, file read, edit/diff, search, web — surfaces as the icon/label) and a
/// bounded text projection of the payload. Dedicated per-tool renderers (rich diff via
/// the WKWebView, structured file/search views) build on this `ChatToolPart` shape and
/// are the documented follow-up; the generic projection is the explicit fallback today.
struct InlineToolResultView: View {
    let part: ChatToolPart
    /// Lean-in mode expands the payload; ambient keeps it to a bounded preview (PRD §9).
    let expanded: Bool

    private static let previewLimit = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(part.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(part.isResult ? "result" : "call")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: Self.icon(for: part.name))
                    .foregroundStyle(.secondary)
            }

            if let text = payloadText, !text.isEmpty {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var payloadText: String? {
        guard let payload = part.payload else { return nil }
        let full = payload.compactText()
        guard expanded else {
            return full.count > Self.previewLimit
                ? String(full.prefix(Self.previewLimit)) + "…"
                : full
        }
        return full
    }

    /// Map a tool name to one of the bounded inline kinds' icons; anything unrecognized
    /// gets the generic-fallback wrench.
    private static func icon(for name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("bash") || lowered.contains("shell") || lowered.contains("terminal") {
            return "terminal"
        }
        if lowered.contains("edit") || lowered.contains("diff") || lowered.contains("write") {
            return "plus.forwardslash.minus"
        }
        if lowered.contains("read") || lowered.contains("cat") || lowered.contains("file") {
            return "doc.text"
        }
        if lowered.contains("search") || lowered.contains("grep") || lowered.contains("glob") || lowered.contains("find") {
            return "magnifyingglass"
        }
        if lowered.contains("web") || lowered.contains("fetch") || lowered.contains("http") || lowered.contains("url") {
            return "globe"
        }
        return "wrench.and.screwdriver"
    }
}
