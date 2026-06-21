import SwiftUI

/// Content of a Workspace window — a `(sceneKind, domainId)` binding over the shared
/// store (CONTEXT.md "Window"). Opened/focused from the switcher by Workspace id, so
/// re-opening the same Workspace focuses the existing window rather than spawning a
/// duplicate. Looks the Workspace up live in the store so a renamed/removed Workspace
/// stays in sync.
///
/// Watch (chat, history, prompting) is Host-gated and lands in a later milestone
/// (ADR-0006); V1 shows the cloud-known identity plus an explicit Host-gated notice.
struct WorkspaceWindowView: View {
    let workspaceID: Workspace.ID?
    let store: WorkspaceStore

    private var workspace: Workspace? {
        guard let workspaceID else { return nil }
        return store.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        if let workspace {
            VStack(alignment: .leading, spacing: 20) {
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
                }

                Label(workspace.status.label, systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)

                ContentUnavailableView(
                    "Watch is Host-gated",
                    systemImage: "eye.slash",
                    description: Text("Live chat, history, and prompting arrive in a later milestone and require a reachable Host (ADR-0006).")
                )
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(workspace.name)
        } else {
            ContentUnavailableView(
                "Workspace unavailable",
                systemImage: "questionmark.square.dashed",
                description: Text("This workspace is no longer in the list.")
            )
        }
    }
}
