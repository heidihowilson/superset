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

    /// Close every open content window except `keep`. Backs the explicit consolidate
    /// action (`keep == nil` closes all).
    static func consolidate(
        except keep: WindowKey?,
        openWindows: OpenWindowsModel,
        dismissWindow: DismissWindowAction
    ) {
        for id in openWindows.openWorkspaceIDs where keep != .workspace(id) {
            dismissWindow(id: WorkspaceScene.windowID, value: id)
        }
        for id in openWindows.openProjectIDs where keep != .project(id) {
            dismissWindow(id: ProjectScene.windowID, value: id)
        }
    }
}

/// Identifies an open content window for consolidation (which kind + which domain id).
enum WindowKey: Equatable {
    case workspace(Workspace.ID)
    case project(Project.ID)
}
