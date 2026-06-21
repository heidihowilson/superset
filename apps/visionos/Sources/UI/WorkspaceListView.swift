import SwiftUI

/// The V1 production Workspace browser: the cloud list grouped by Project (PRD §7.2).
/// Observes the shared store and emits a `select` intent on tap (which opens/focuses
/// the Workspace window); ≥60pt targets and explicit button shapes per the headset
/// HIG (PRD §9). Cache-first: existing rows always render; the load state only drives
/// the empty case (AGENTS rule 9 analog for the polled list).
struct WorkspaceListView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow

    @State private var isCreating = false
    @State private var renameTarget: Workspace?
    @State private var deleteTarget: Workspace?

    var body: some View {
        Group {
            if store.workspaces.isEmpty {
                emptyState
            } else {
                grouped
            }
        }
        .navigationTitle("Workspaces")
        .toolbar {
            if store.supportsLifecycle {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New Workspace", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            WorkspaceCreateView(store: store)
        }
        .sheet(item: $renameTarget) { workspace in
            WorkspaceRenameView(store: store, workspace: workspace)
        }
        .confirmationDialog(
            "Delete this workspace?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { workspace in
            Button("Delete \(workspace.name)", role: .destructive) {
                Task { await store.delete(workspace) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the worktree on the Host. This cannot be undone.")
        }
        .alert(
            "Couldn't complete that",
            isPresented: lifecycleErrorBinding,
            presenting: store.lifecycleError
        ) { _ in
            Button("OK") { store.clearLifecycleError() }
        } message: { message in
            Text(message)
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var lifecycleErrorBinding: Binding<Bool> {
        Binding(
            get: { store.lifecycleError != nil },
            set: { if !$0 { store.clearLifecycleError() } }
        )
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
                                    isSelected: workspace.id == store.selectedWorkspaceID,
                                    isPending: store.pendingWorkspaceIDs.contains(workspace.id)
                                )
                            }
                            .buttonBorderShape(.roundedRectangle)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if store.supportsLifecycle {
                                    Button(role: .destructive) {
                                        deleteTarget = workspace
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        renameTarget = workspace
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.indigo)
                                }
                            }
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
    let isPending: Bool

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
            if isPending {
                ProgressView()
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .frame(minHeight: 60)
        .opacity(isPending ? 0.6 : 1)
        .contentShape(Rectangle())
    }
}
