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
    @State private var composer = ComposerStore()
    @Environment(OpenWindowsModel.self) private var openWindows
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneActive = false

    private var workspace: Workspace? {
        guard let workspaceID else { return nil }
        return store.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        Group {
            if let workspace {
                workspaceContent(workspace)
                    .navigationTitle(workspace.name)
            } else if store.loadState == .loaded {
                // The list has loaded and this id is absent — a deleted Workspace, not a
                // slow restore. Show the 404 surface, not a spinner (PRD §16.2).
                ContentUnavailableView(
                    "Workspace unavailable",
                    systemImage: "questionmark.square.dashed",
                    description: Text("This workspace is no longer in the list. It may have been deleted.")
                )
            } else {
                // Restored onto a not-yet-loaded list: keep loading until the poll lands,
                // so a valid restored Workspace resolves to content rather than a false 404.
                ProgressView("Loading workspace…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            store.beginPolling()
            syncForeground(scenePhase)
            if let workspaceID { openWindows.registerWorkspace(workspaceID) }
        }
        .onDisappear {
            syncForeground(.background)
            chat.stopPolling()
            store.endPolling()
            if let workspaceID { openWindows.unregisterWorkspace(workspaceID) }
        }
        // Bind/start the watch poll once the Workspace resolves. Keyed off the resolved
        // workspace id (not the passed-in id) so a restored/deep-linked window — which has
        // a non-nil id before the list loads — re-runs this when the Workspace appears
        // (nil→non-nil), and re-keys when the window is retargeted to a different id.
        .task(id: workspace?.id) {
            guard let workspace, let provider = auth.makeChatTranscriptProvider(for: workspace) else { return }
            chat.bind(provider: provider, workspaceID: workspace.id)
            chat.startPolling()
            if let sender = auth.makeChatSender(for: workspace) {
                composer.bind(sender: sender, workspaceID: workspace.id) {
                    // A sent prompt should appear without waiting for the next poll tick.
                    Task { await chat.refresh() }
                }
                await composer.loadPickers()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            syncForeground(phase)
            if phase == .active {
                chat.startPolling()
            } else {
                chat.stopPolling()
                auth.dropRelayToken()
            }
        }
    }

    /// Report this scene's active-ness to the shared store, contributing exactly one to
    /// its active-scene count and keeping register/unregister balanced across phase
    /// changes and window close (so one inactive window can't pause the shared list poll
    /// for others). The per-window watch poll is gated separately above.
    private func syncForeground(_ phase: ScenePhase) {
        let active = phase == .active
        guard active != sceneActive else { return }
        sceneActive = active
        if active { store.sceneBecameActive() } else { store.sceneResignedActive() }
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
                ComposerView(store: composer)
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
