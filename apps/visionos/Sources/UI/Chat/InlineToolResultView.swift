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
    /// Lean-in shows far more than the ambient preview, but stays bounded so a giant
    /// payload can't flood the transcript (the "open full" host fetch, PRD §7.2, is the
    /// later affordance for the untruncated body).
    private static let expandedLimit = 20_000

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
        // `compactText` bounds the projection itself, so pass the lean-in/ambient limit
        // directly — ambient previews tightly, lean-in shows the larger bounded body.
        return payload.compactText(limit: expanded ? Self.expandedLimit : Self.previewLimit)
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
