import SwiftUI

/// The native watch transcript shell (PRD §7.2/§9): a glanceable header + an ordered
/// message list, fed by the polled `ChatSessionStore`. Two presentations over one
/// store — an **ambient** default (status + prose, thinking hidden, tool payloads
/// previewed) and a **lean-in** full-fidelity mode (thinking expanded, tool payloads
/// full). The shell, list, and chrome are native (ADR-0003); only rich prose escapes
/// to the WKWebView (ADR-0009).
///
/// Cache-first (the M0c gate): existing messages always render; `loadState` only drives
/// the *empty* state, so a poll in flight, a failed poll, or a backgrounding cycle
/// never blanks the shown transcript.
struct TranscriptView: View {
    let store: ChatSessionStore
    @State private var leanIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            statusBadge
            Spacer(minLength: 12)
            Picker("Detail", selection: $leanIn) {
                Text("Ambient").tag(false)
                Text("Full").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let error = store.transcript.displayState.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if store.transcript.displayState.isRunning {
            Label {
                Text("Agent is working…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.headline)
        } else {
            Label("Idle", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.transcript.messages.isEmpty {
            transcriptList
        } else {
            switch store.loadState {
            case .loading, .idle:
                ProgressView("Loading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView(
                    "Can't watch yet",
                    systemImage: "eye.slash",
                    description: Text(message)
                )
            case .loaded:
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start a conversation from this Workspace to see it here.")
                )
            }
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(store.transcript.messages) { message in
                        MessageRowView(message: message, leanIn: leanIn)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(24)
            }
            .onChange(of: scrollSignal) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    /// The transcript facts that should pull the view to the bottom: a new message, the
    /// last message's id changing, a new part on it, or it growing in place while it
    /// streams. Keying only on `last.id` missed in-place growth — streamed prose rendered
    /// off-screen until a new id landed.
    private var scrollSignal: TranscriptScrollSignal {
        let messages = store.transcript.messages
        let last = messages.last
        return TranscriptScrollSignal(
            count: messages.count,
            lastID: last?.id,
            lastPartCount: last?.content.count ?? 0,
            lastContentLength: last?.contentLength ?? 0
        )
    }

    private struct TranscriptScrollSignal: Equatable {
        let count: Int
        let lastID: String?
        let lastPartCount: Int
        let lastContentLength: Int
    }

    private static let bottomAnchor = "transcript-bottom"
}
