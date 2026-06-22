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
    @State private var branch = ""
    /// True once the user types in the Branch field, which stops the name→branch
    /// auto-slug from overwriting their explicit choice (matches the desktop, whose
    /// branchName field pre-fills from the name until the user edits it).
    @State private var branchEdited = false
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
                            .onChange(of: name) { _, newValue in
                                if !branchEdited { branch = Self.branchSlug(from: newValue) }
                            }
                    }
                    Section("Branch") {
                        TextField("Branch name", text: $branch)
                            .textInputAutocapitalization(.never)
                            .onChange(of: branch) { _, _ in branchEdited = true }
                    }
                    Section("Project") {
                        Picker("Project", selection: $projectID) {
                            ForEach(store.projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                        .pickerStyle(.menu)
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
                            .pickerStyle(.menu)
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
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranch = trimmedBranch.isEmpty ? Self.branchSlug(from: trimmedName) : trimmedBranch
        Task {
            await store.createWorkspace(
                projectID: projectID,
                name: trimmedName,
                branch: resolvedBranch,
                hostID: hostID
            )
            if store.lifecycleError == nil { dismiss() }
        }
    }

    /// A git-safe branch slug derived from the workspace name: lowercased, with runs of
    /// non-`[a-z0-9._/]` characters collapsed to a single hyphen and leading/trailing
    /// separators trimmed. The Host re-prefixes and de-duplicates the final branch, so this
    /// only needs to be a reasonable starting point (mirrors the desktop's branchName default).
    static func branchSlug(from name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._/")
        var slug = ""
        var pendingSeparator = false
        for character in name.lowercased() {
            if allowed.contains(character) {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-._/"))
    }
}

#Preview {
    WorkspaceCreateView(store: .sample())
}
