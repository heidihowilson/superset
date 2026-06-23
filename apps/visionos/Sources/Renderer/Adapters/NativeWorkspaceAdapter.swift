import SwiftUI

/// V1 production presentation: a native SwiftUI Workspace list (ADR-0003).
struct NativeWorkspaceAdapter: WorkspaceAdapter {
    let id = "native-2d"

    func view(for kind: PaneKind, store: WorkspaceStore) -> AnyView {
        switch kind {
        case .workspaceList:
            AnyView(WorkspaceListView(store: store))
        }
    }
}
