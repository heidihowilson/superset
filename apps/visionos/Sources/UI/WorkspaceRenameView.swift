import SwiftUI

/// Sheet for renaming a Workspace (PRD §7.2 lifecycle, M0e). Rename is cloud-only, so it
/// succeeds even while the Host is offline (PRD §6.3, ADR-0006). Non-optimistic: the row
/// keeps its old name with a pending state until the post-rename poll lands the change.
struct WorkspaceRenameView: View {
    @Bindable var store: WorkspaceStore
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(store: WorkspaceStore, workspace: Workspace) {
        self.store = store
        self.workspace = workspace
        _name = State(initialValue: workspace.name)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmed.isEmpty && trimmed != workspace.name && !isPending
    }

    private var isPending: Bool {
        store.pendingWorkspaceIDs.contains(workspace.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Workspace name", text: $name)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Rename Workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPending {
                        ProgressView()
                    } else {
                        Button("Save") { submit() }
                            .disabled(!canSubmit)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 240)
    }

    private func submit() {
        let newName = trimmed
        Task {
            await store.rename(workspace, to: newName)
            if store.lifecycleError == nil { dismiss() }
        }
    }
}

#Preview {
    WorkspaceRenameView(
        store: .sample(),
        workspace: Workspace(
            id: "ws-auth",
            name: "auth-handoff",
            projectID: "p-superset",
            projectName: "superset",
            status: .hostOnline,
            hostID: "host-1"
        )
    )
}
