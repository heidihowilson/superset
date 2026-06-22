import SwiftUI

/// Centralizes opening/consolidating content windows so the switcher, the list, and
/// deep links all share one policy (PRD §7.1/§9/§10). The active `InteractionModel`
/// decides whether an open spawns a coexisting window (multi-window) or first
/// consolidates the others (single-window-plus-switcher). The SwiftUI window actions
/// are passed in because they live in the view environment, not the model layer.
@MainActor
enum WindowRouter {
    /// Resolve a parsed deep link to a content window. `.authCallback` is a no-op here —
    /// it is validated by `AuthController`, not routed to a scene.
    static func open(
        _ route: DeepLinkRoute,
        store: WorkspaceStore,
        models: InteractionModelRegistry,
        openWindows: OpenWindowsModel,
        sessionIDs: SessionIDStore = SessionIDStore(),
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) {
        switch route {
        case .authCallback:
            break
        case let .workspace(id):
            openWorkspace(id, store: store, models: models, openWindows: openWindows, openWindow: openWindow, dismissWindow: dismissWindow)
        case let .project(id):
            openProject(id, models: models, openWindows: openWindows, openWindow: openWindow, dismissWindow: dismissWindow)
        case let .session(sessionID):
            // Only a session this device minted resolves to a Workspace (ADR-0010); a
            // foreign session id has no V1 scene and is intentionally ignored.
            if let workspaceID = sessionIDs.workspaceID(forSession: sessionID) {
                openWorkspace(workspaceID, store: store, models: models, openWindows: openWindows, openWindow: openWindow, dismissWindow: dismissWindow)
            }
        }
    }

    static func openWorkspace(
        _ id: Workspace.ID,
        store: WorkspaceStore,
        models: InteractionModelRegistry,
        openWindows: OpenWindowsModel,
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) {
        // Open/focus the target before consolidating the rest: dismissing the current
        // window and opening the new one in the same turn makes SwiftUI coalesce the
        // dismiss with the open and drop the new scene, so the tap appears to do nothing
        // (the "sessions won't open" dogfood bug). Opening first guarantees the target
        // scene is presented; the redundant windows are then closed behind it.
        store.select(id)
        openWindow(id: WorkspaceScene.windowID, value: id)
        consolidateIfSingleWindow(except: .workspace(id), models: models, openWindows: openWindows, dismissWindow: dismissWindow)
    }

    static func openProject(
        _ id: Project.ID,
        models: InteractionModelRegistry,
        openWindows: OpenWindowsModel,
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) {
        openWindow(id: ProjectScene.windowID, value: id)
        consolidateIfSingleWindow(except: .project(id), models: models, openWindows: openWindows, dismissWindow: dismissWindow)
    }

    /// Close every open content window except `keep`. Backs the explicit consolidate
    /// action (`keep == nil` closes all) and the single-window policy's close-on-open.
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

    private static func consolidateIfSingleWindow(
        except keep: WindowKey,
        models: InteractionModelRegistry,
        openWindows: OpenWindowsModel,
        dismissWindow: DismissWindowAction
    ) {
        guard models.activeModel.windowing == .singleWindowPlusSwitcher else { return }
        consolidate(except: keep, openWindows: openWindows, dismissWindow: dismissWindow)
    }
}

/// Identifies an open content window for consolidation (which kind + which domain id).
enum WindowKey: Equatable {
    case workspace(Workspace.ID)
    case project(Project.ID)
}
