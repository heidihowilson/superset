import SwiftUI

/// Native visionOS Superset client. V1 runs in the Shared Space (plain
/// `WindowGroup`s, no `ImmersiveSpace`); the system owns window placement and the app
/// passes only a `defaultSize` hint (PRD §7.1, PI-1).
///
/// Owns the app-wide `AuthController` and the cloud-backed `WorkspaceStore` so both
/// the root window and the per-Workspace windows render the same store. Workspace
/// windows are keyed by Workspace id, so opening an already-open Workspace focuses its
/// window instead of spawning a duplicate.
@main
struct SupersetApp: App {
    @State private var auth: AuthController
    @State private var store: WorkspaceStore

    init() {
        let auth = AuthController()
        _auth = State(initialValue: auth)
        _store = State(initialValue: WorkspaceStore(
            provider: auth.makeWorkspaceListProvider(),
            cache: FileWorkspaceListCache()
        ))
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView(auth: auth, store: store)
        }
        .defaultSize(width: 760, height: 820)

        WindowGroup(id: WorkspaceScene.windowID, for: Workspace.ID.self) { $workspaceID in
            WorkspaceWindowView(workspaceID: workspaceID, store: store)
        }
        .defaultSize(width: 720, height: 720)
    }
}
