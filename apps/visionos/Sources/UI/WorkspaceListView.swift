import SwiftUI

/// The V1 production Workspace browser: a collapsible project→workspace tree (IA V1.1,
/// ADR-0011). Workspaces are grouped by Project only — status is a per-row indicator, never
/// a section — and each project is a foldable `DisclosureGroup` so the list stays short on a
/// coarse gaze-scroll surface (one scroll axis). Fold state persists per window; an optional
/// search filters the tree. Tapping a workspace opens its own window (`WindowRouter`).
///
/// Observes the shared store; ≥60pt targets and explicit button shapes per the headset HIG
/// (PRD §9). Cache-first: existing rows always render; the load state only drives the empty
/// case (AGENTS rule 9 analog for the polled list).
struct WorkspaceListView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow

    @State private var isCreating = false
    @State private var renameTarget: Workspace?
    @State private var deleteTarget: Workspace?
    @State private var searchText = ""
    /// Per-window fold state: the JSON-encoded ids of the *collapsed* projects (groups are
    /// expanded by default, so an empty set means all-open). `@SceneStorage` keeps each window's
    /// folding independent and restored across relaunch, per the IA spec.
    @SceneStorage("workspaceTree.collapsedProjects") private var collapsedProjectsJSON = ""

    var body: some View {
        Group {
            if store.workspaces.isEmpty {
                emptyState
            } else {
                tree
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

    private var tree: some View {
        List {
            ForEach(displayedGroups) { group in
                DisclosureGroup(isExpanded: expansion(for: group.id)) {
                    if group.workspaces.isEmpty {
                        Text("No workspaces")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(group.workspaces) { workspace in
                            workspaceRow(workspace)
                        }
                    }
                } label: {
                    ProjectHeader(
                        name: group.name,
                        count: group.workspaces.count,
                        isCollapsed: !expansion(for: group.id).wrappedValue
                    )
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter workspaces")
        .overlay {
            if displayedGroups.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .accessibilityIdentifier(AccessibilityID.workspaceList)
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        Button {
            WindowRouter.openWorkspace(
                workspace.id,
                store: store,
                openWindow: openWindow
            )
        } label: {
            WorkspaceRowView(
                workspace: workspace,
                isSelected: workspace.id == store.selectedWorkspaceID,
                isPending: store.pendingWorkspaceIDs.contains(workspace.id)
            )
        }
        .buttonBorderShape(.roundedRectangle)
        .accessibilityIdentifier(AccessibilityID.workspaceRow(workspace.id))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if store.supportsLifecycle {
                Button(role: .destructive) {
                    deleteTarget = workspace
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!store.canDelete(workspace))
                Button {
                    renameTarget = workspace
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.indigo)
            }
        }
    }

    /// Project groups to render: the store's full set, or — while searching — only the projects
    /// whose name or workspaces match, with non-matching workspaces filtered out. A project whose
    /// own name matches keeps all its workspaces.
    private var displayedGroups: [WorkspaceGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.groups }
        return store.groups.compactMap { group in
            if group.name.localizedCaseInsensitiveContains(query) { return group }
            let matches = group.workspaces.filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
            guard !matches.isEmpty else { return nil }
            return WorkspaceGroup(id: group.id, name: group.name, workspaces: matches)
        }
    }

    /// Expansion binding for a project's `DisclosureGroup`, backed by the per-window collapsed
    /// set. While a search is active every shown group is forced open so matches are visible, and
    /// toggles aren't persisted — the saved fold state returns when the search clears.
    private func expansion(for groupID: String) -> Binding<Bool> {
        Binding(
            get: { !searchText.isEmpty || !collapsedProjects.contains(groupID) },
            set: { isExpanded in
                guard searchText.isEmpty else { return }
                var collapsed = collapsedProjects
                if isExpanded { collapsed.remove(groupID) } else { collapsed.insert(groupID) }
                collapsedProjects = collapsed
            }
        )
    }

    /// The persisted collapsed-project ids, decoded from / encoded to `@SceneStorage` as JSON.
    private var collapsedProjects: Set<String> {
        get {
            guard let data = collapsedProjectsJSON.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(ids)
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue.sorted()),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            collapsedProjectsJSON = json
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

/// A foldable project header: the project name, plus a count hint of how many workspaces are
/// hidden while the group is collapsed (per the IA sketch — the count surfaces only when folded).
private struct ProjectHeader: View {
    let name: String
    let count: Int
    let isCollapsed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.headline)
            if isCollapsed {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(count) workspaces")
            }
        }
        .frame(minHeight: 44)
    }
}
