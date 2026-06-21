import SwiftUI

/// Native visionOS Superset client. V1 runs in the Shared Space (plain
/// `WindowGroup`s, no `ImmersiveSpace`); the system owns window placement and the app
/// passes only a `defaultSize` hint (PRD §7.1, PI-1).
///
/// Owns the app-wide singletons the windows share: the `AuthController`, the
/// cloud-backed `WorkspaceStore`, the `InteractionModelRegistry` (the §10 windowing
/// flag), and the `OpenWindowsModel` (the roster backing consolidate). Workspace and
/// Project windows are `WindowGroup(for:)` scenes keyed by domain id, so opening an
/// already-open id focuses its window instead of spawning a duplicate (PRD §7.1).
/// Both restore on relaunch (intent, not just geometry — PRD §16.2): the restored view
/// reloads against the shared store and shows a 404 surface for a deleted id.
@main
struct SupersetApp: App {
    @State private var auth: AuthController
    @State private var store: WorkspaceStore
    @State private var lock: LockController
    @State private var models = InteractionModelRegistry()
    @State private var openWindows = OpenWindowsModel()
    @State private var appSettings = AppSettingsStore()

    init() {
        let auth = AuthController()
        _auth = State(initialValue: auth)
        _store = State(initialValue: WorkspaceStore(
            provider: auth.makeWorkspaceListProvider(),
            lifecycle: auth.makeWorkspaceLifecycleClient(),
            cache: FileWorkspaceListCache()
        ))
        // The Optic ID gate sits over every signed-in window and shares the relay
        // credential with `auth`, so locking seals the RCE-grade JWT app-wide (ADR-0008).
        _lock = State(initialValue: LockController(relay: auth))
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView(auth: auth, store: store, models: models, openWindows: openWindows)
                .lockGate(lock: lock, auth: auth)
                .preferredColorScheme(appSettings.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 820)

        WindowGroup(id: WorkspaceScene.windowID, for: Workspace.ID.self) { $workspaceID in
            WorkspaceWindowView(workspaceID: workspaceID, store: store, auth: auth)
                .environment(models)
                .environment(openWindows)
                .environment(appSettings)
                .lockGate(lock: lock, auth: auth)
                .preferredColorScheme(appSettings.appearance.colorScheme)
        }
        .defaultSize(width: 720, height: 720)
        .restorationBehavior(.automatic)

        WindowGroup(id: ProjectScene.windowID, for: Project.ID.self) { $projectID in
            ProjectWindowView(projectID: projectID, store: store)
                .environment(models)
                .environment(openWindows)
                .lockGate(lock: lock, auth: auth)
                .preferredColorScheme(appSettings.appearance.colorScheme)
        }
        .defaultSize(width: 640, height: 720)
        .restorationBehavior(.automatic)

        WindowGroup(id: SettingsScene.windowID) {
            SettingsView(auth: auth, store: store)
                .environment(appSettings)
                .lockGate(lock: lock, auth: auth)
                .preferredColorScheme(appSettings.appearance.colorScheme)
        }
        .defaultSize(width: 560, height: 720)
        .restorationBehavior(.automatic)
    }
}
