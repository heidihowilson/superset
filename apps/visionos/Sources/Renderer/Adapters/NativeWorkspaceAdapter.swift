import SwiftUI

/// V1 production presentation: a native SwiftUI Workspace list (ADR-0003), the
/// `single-window-plus-switcher` default interaction model (PRD §10). Live kinds
/// render real views; deferred kinds fall back to registered placeholders (PRD §8).
struct NativeWorkspaceAdapter: WorkspaceAdapter {
    let id = "native-2d"
    let displayName = "Native 2D"

    func view(for kind: PaneKind, store: WorkspaceStore) -> AnyView {
        switch kind {
        case .workspaceList:
            AnyView(WorkspaceListView(store: store))
        case .chat, .diff, .file, .comment, .terminal, .browser:
            AnyView(PlaceholderPaneView(kind: kind))
        }
    }
}
