import SwiftUI

/// The Debug window scene id. A plain `WindowGroup` (no domain value) — one shared
/// Debug window, opened from the Settings "Debug" category.
enum DebugScene {
    static let windowID = "debug"
}

/// A plain-text dump of the shared `WorkspaceStore` — including live selection — opened
/// as its own window from Settings. A developer surface for inspecting store state at a
/// glance, unconnected to the production UI.
struct DebugDumpView: View {
    let store: WorkspaceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("WorkspaceStore — \(store.workspaces.count) workspaces")
                    .font(.headline)
                ForEach(store.workspaces) { workspace in
                    let marker = workspace.id == store.selectedWorkspaceID ? "  ← selected" : ""
                    Text("• [\(workspace.status.rawValue)] \(workspace.projectName)/\(workspace.name)\(marker)")
                        .font(.system(.body, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
