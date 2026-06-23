import SwiftUI

/// Centralizes opening/consolidating content windows so the switcher, the list, and
/// deep links all share one policy (PRD §7.1/§9). Opening a Workspace/Project always
/// spawns or focuses its own window (multi-window); the explicit consolidate action
/// (§9) is the manual mitigation for proliferation. The SwiftUI window actions are
/// passed in because they live in the view environment, not the model layer.
@MainActor
enum WindowRouter {
    /// Resolve a parsed deep link to a content window. `.authCallback` is a no-op here —
    /// it is validated by `AuthController`, not routed to a scene.
    static func open(
        _ route: DeepLinkRoute,
        store: WorkspaceStore,
        sessionIDs: SessionIDStore = SessionIDStore(),
        openWindow: OpenWindowAction
    ) {
        switch route {
        case .authCallback:
            break
        case let .workspace(id):
            openWorkspace(id, store: store, openWindow: openWindow)
        case let .project(id):
            openProject(id, openWindow: openWindow)
        case let .session(sessionID):
            // Only a session this device minted resolves to a Workspace (ADR-0010); a
            // foreign session id has no V1 scene and is intentionally ignored.
            if let workspaceID = sessionIDs.workspaceID(forSession: sessionID) {
                openWorkspace(workspaceID, store: store, openWindow: openWindow)
            }
        }
    }

    static func openWorkspace(
        _ id: Workspace.ID,
        store: WorkspaceStore,
        openWindow: OpenWindowAction
    ) {
        store.select(id)
        openWindow(id: WorkspaceScene.windowID, value: id)
    }

    static func openProject(
        _ id: Project.ID,
        openWindow: OpenWindowAction
    ) {
        openWindow(id: ProjectScene.windowID, value: id)
    }

    /// Close every open content window. Backs the explicit consolidate action (§9).
    static func consolidate(
        openWindows: OpenWindowsModel,
        dismissWindow: DismissWindowAction
    ) {
        for id in openWindows.openWorkspaceIDs {
            dismissWindow(id: WorkspaceScene.windowID, value: id)
        }
        for id in openWindows.openProjectIDs {
            dismissWindow(id: ProjectScene.windowID, value: id)
        }
    }
}
