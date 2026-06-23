import SwiftUI

/// One transcript message, dispatching its ordered content parts to the bounded
/// renderers (PRD §7.2): assistant prose to the WKWebView content surface (ADR-0009),
/// reasoning to a native collapsible, tool calls/results to the inline card, and
/// anything else to a generic label. Two presentations over one model (PRD §9): the
/// `leanIn` flag expands thinking and tool payloads; ambient keeps them glanceable.
struct MessageRowView: View {
    let message: ChatMessage
    let leanIn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            roleLabel
            ForEach(Array(message.content.enumerated()), id: \.offset) { _, part in
                partView(part)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var roleLabel: some View {
        Text(roleTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var roleTitle: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Agent"
        case .system: return "System"
        case .other: return "Message"
        }
    }

    @ViewBuilder
    private func partView(_ part: ChatMessagePart) -> some View {
        switch part {
        case let .text(text):
            if message.role == .assistant {
                // Rich prose renders in the web surface; user/system text stays native.
                MarkdownWebText(markdown: text)
            } else {
                Text(text)
                    .font(.title3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .reasoning(text):
            if leanIn {
                ReasoningDisclosure(text: text)
            } else {
                EmptyView()
            }
        case let .tool(toolPart):
            InlineToolResultView(part: toolPart, expanded: leanIn)
        case let .attachment(name, mediaType):
            Label(name ?? mediaType ?? "Attachment", systemImage: "paperclip")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case let .other(type):
            Label(type, systemImage: "ellipsis.rectangle")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Agent reasoning in lean-in mode. Expanded by default so the thinking is visible on
/// glance (PRD §9), while still collapsible to reclaim space. Owns its own expansion
/// state so each reasoning block tracks independently.
private struct ReasoningDisclosure: View {
    let text: String
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
