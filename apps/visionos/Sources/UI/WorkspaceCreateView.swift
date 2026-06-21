import SwiftUI

/// Sheet for creating a Workspace (PRD §7.2 lifecycle, M0e). Create is Host-gated: it
/// needs a Project to create under and an **online** Host to provision the worktree on
/// (ADR-0006), so the form requires both plus a name. The store runs the relay saga and
/// the new row appears on the next poll (non-optimistic); a failure surfaces via the
/// list's lifecycle-error alert.
struct WorkspaceCreateView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var projectID: String?
    @State private var hostID: String?

    private var canSubmit: Bool {
        projectID != nil
            && hostID.map(store.canCreate(onHostID:)) == true
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.isCreatingWorkspace
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.projects.isEmpty {
                    Text("Create a Project first to add a Workspace to it.")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Name") {
                        TextField("Workspace name", text: $name)
                            .textInputAutocapitalization(.never)
                    }
                    Section("Project") {
                        Picker("Project", selection: $projectID) {
                            ForEach(store.projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    Section("Host") {
                        if store.paidPlan == false {
                            Text("This organization's plan doesn't allow Host actions. Upgrade to an active plan to create a workspace.")
                                .foregroundStyle(.secondary)
                        } else if store.onlineHosts.isEmpty {
                            Text("No online Host. A Host must be online to create a workspace.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Host", selection: $hostID) {
                                ForEach(store.onlineHosts) { host in
                                    Text(host.name).tag(Optional(host.id))
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                }
            }
            .navigationTitle("New Workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isCreatingWorkspace {
                        ProgressView()
                    } else {
                        Button("Create") { submit() }
                            .disabled(!canSubmit)
                    }
                }
            }
            .onAppear {
                if projectID == nil { projectID = store.projects.first?.id }
                if hostID == nil { hostID = store.onlineHosts.first?.id }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func submit() {
        guard let projectID, let hostID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await store.createWorkspace(projectID: projectID, name: trimmed, hostID: hostID)
            if store.lifecycleError == nil { dismiss() }
        }
    }
}

#Preview {
    WorkspaceCreateView(store: .sample())
}
