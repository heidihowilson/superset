import SwiftUI

/// Content of a Workspace window — a `(sceneKind, domainId)` binding over the shared
/// store (CONTEXT.md "Window"). Opened/focused from the switcher by Workspace id, so
/// re-opening the same Workspace focuses the existing window rather than spawning a
/// duplicate. Looks the Workspace up live in the store so a renamed/removed Workspace
/// stays in sync.
///
/// Hosts the Watch transcript (M0c): a per-window `ChatSessionStore` polls
/// `chat.getSnapshot` over the relay while the window is active and pauses on
/// background, dropping the relay JWT (ADR-0006/0008). A Workspace with no Host shows
/// the Host-gated notice instead — there is nothing to watch.
struct WorkspaceWindowView: View {
    let workspaceID: Workspace.ID?
    let store: WorkspaceStore
    let auth: AuthController

    @State private var chat = ChatSessionStore()
    @Environment(\.scenePhase) private var scenePhase

    private var workspace: Workspace? {
        guard let workspaceID else { return nil }
        return store.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        Group {
            if let workspace {
                workspaceContent(workspace)
                    .navigationTitle(workspace.name)
            } else {
                ContentUnavailableView(
                    "Workspace unavailable",
                    systemImage: "questionmark.square.dashed",
                    description: Text("This workspace is no longer in the list.")
                )
            }
        }
        // Bind/start the watch poll for this Workspace; re-keys when the window is
        // retargeted to a different Workspace id.
        .task(id: workspaceID) {
            guard let workspace, let provider = auth.makeChatTranscriptProvider(for: workspace) else { return }
            chat.bind(provider: provider, workspaceID: workspace.id)
            chat.startPolling()
        }
        .onDisappear { chat.stopPolling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                chat.startPolling()
            } else {
                chat.stopPolling()
                auth.dropRelayToken()
            }
        }
    }

    @ViewBuilder
    private func workspaceContent(_ workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            identityHeader(workspace)
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 16)

            if workspace.hostID == nil {
                ContentUnavailableView(
                    "Watch is Host-gated",
                    systemImage: "eye.slash",
                    description: Text("This Workspace has no reachable Host. Watch requires a Host running host-service (ADR-0006).")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(store: chat)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func identityHeader(_ workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(workspace.status.tint)
                .frame(width: 16, height: 16)
                .accessibilityLabel(workspace.status.label)
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name).font(.largeTitle)
                Text(workspace.projectName.isEmpty ? "No project" : workspace.projectName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
