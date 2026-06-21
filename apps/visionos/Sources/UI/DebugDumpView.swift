import SwiftUI

/// The throwaway second adapter's view (M0). Reads the *same* `WorkspaceStore` as
/// the native list — including live selection — and presents it as a plain text
/// dump. Deliberately unlike the production UI so the renderer seam is visible at a
/// glance: same store, different presentation, zero domain change (PRD §17, M0).
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
