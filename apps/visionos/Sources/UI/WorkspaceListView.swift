import SwiftUI

/// The V1 production Workspace browser: the cloud list grouped by Project (PRD §7.2).
/// Observes the shared store and emits a `select` intent on tap (which opens/focuses
/// the Workspace window); ≥60pt targets and explicit button shapes per the headset
/// HIG (PRD §9). Cache-first: existing rows always render; the load state only drives
/// the empty case (AGENTS rule 9 analog for the polled list).
struct WorkspaceListView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if store.workspaces.isEmpty {
                emptyState
            } else {
                grouped
            }
        }
        .navigationTitle("Workspaces")
    }

    private var grouped: some View {
        List {
            ForEach(store.groups) { group in
                Section(group.name) {
                    if group.workspaces.isEmpty {
                        Text("No workspaces")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(group.workspaces) { workspace in
                            Button {
                                store.select(workspace.id)
                                openWindow(id: WorkspaceScene.windowID, value: workspace.id)
                            } label: {
                                WorkspaceRow(
                                    workspace: workspace,
                                    isSelected: workspace.id == store.selectedWorkspaceID
                                )
                            }
                            .buttonBorderShape(.roundedRectangle)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch store.loadState {
        case .loading, .idle:
            ProgressView("Loading workspaces…")
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't load workspaces", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await store.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded:
            ContentUnavailableView(
                "No workspaces",
                systemImage: "square.stack.3d.up.slash",
                description: Text("Create a workspace on a Host to see it here.")
            )
        }
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
                Text(workspace.status.label)
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
