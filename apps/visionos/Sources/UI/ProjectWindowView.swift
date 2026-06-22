import SwiftUI

/// Identifiers for the Project window scene, shared by the App (which declares the
/// `WindowGroup`) and the router (which opens it by Project id).
enum ProjectScene {
    static let windowID = "project"
}

/// Content of a Project window — a `(sceneKind, domainId)` binding over the shared store
/// (CONTEXT.md "Window"), keyed by Project id so re-opening focuses the existing window.
/// Lists the Project's Workspaces and opens each into its own Workspace window
/// (multi-window). Cache-first restoration (PRD §16.2): a restored window
/// onto a still-loading list shows progress; only a Project absent from a *loaded* list
/// is a deleted-id 404 surface, never a spinner that hangs.
struct ProjectWindowView: View {
    let projectID: Project.ID?
    let store: WorkspaceStore

    @Environment(OpenWindowsModel.self) private var openWindows
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneActive = false

    private var project: Project? {
        guard let projectID else { return nil }
        return store.projects.first { $0.id == projectID }
    }

    private var projectWorkspaces: [Workspace] {
        guard let projectID else { return [] }
        return store.workspaces
            .filter { $0.projectID == projectID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                store.beginPolling()
                syncForeground(scenePhase)
                if let projectID { openWindows.registerProject(projectID) }
            }
            .onDisappear {
                syncForeground(.background)
                store.endPolling()
                if let projectID { openWindows.unregisterProject(projectID) }
            }
            .onChange(of: scenePhase) { _, phase in
                syncForeground(phase)
            }
    }

    /// Report this scene's active-ness to the shared store, contributing exactly one to
    /// its active-scene count and keeping register/unregister balanced across phase
    /// changes and window close (so one inactive window can't pause polling for others).
    private func syncForeground(_ phase: ScenePhase) {
        let active = phase == .active
        guard active != sceneActive else { return }
        sceneActive = active
        if active { store.sceneBecameActive() } else { store.sceneResignedActive() }
    }

    @ViewBuilder
    private var content: some View {
        if let project {
            projectContent(project)
                .navigationTitle(project.name)
        } else if store.loadState == .loaded {
            ContentUnavailableView(
                "Project unavailable",
                systemImage: "questionmark.folder",
                description: Text("This project is no longer in the list. It may have been deleted.")
            )
        } else {
            ProgressView("Loading project…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func projectContent(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(project.name)
                .font(.largeTitle)
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 16)

            if projectWorkspaces.isEmpty {
                ContentUnavailableView(
                    "No workspaces",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("This project has no workspaces yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(projectWorkspaces) { workspace in
                    Button {
                        WindowRouter.openWorkspace(
                            workspace.id,
                            store: store,
                            openWindow: openWindow
                        )
                    } label: {
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
                        }
                        .frame(minHeight: 60)
                        .contentShape(Rectangle())
                    }
                    .buttonBorderShape(.roundedRectangle)
                }
            }
        }
    }
}
