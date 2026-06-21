import SwiftUI

/// The V1 production Workspace list. Observes the shared store and emits a `select`
/// intent on tap; ≥60pt targets and explicit button shapes per the headset HIG (PRD §9).
struct WorkspaceListView: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        List(store.workspaces) { workspace in
            Button {
                store.select(workspace.id)
            } label: {
                WorkspaceRow(
                    workspace: workspace,
                    isSelected: workspace.id == store.selectedWorkspaceID
                )
            }
            .buttonBorderShape(.roundedRectangle)
        }
        .navigationTitle("Workspaces")
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(workspace.status.tint)
                .frame(width: 14, height: 14)
                .accessibilityLabel(workspace.status.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).font(.headline)
                Text(workspace.projectName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}
