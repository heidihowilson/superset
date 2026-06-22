import SwiftUI

/// Native visionOS Superset client. V1 runs in the Shared Space (plain
/// `WindowGroup`s, no `ImmersiveSpace`); the system owns window placement and the app
/// passes only a `defaultSize` hint (PRD §7.1, PI-1).
///
/// Owns the app-wide singletons the windows share: the `AuthController`, the
/// cloud-backed `WorkspaceStore`, and the `OpenWindowsModel` (the roster backing the
/// explicit consolidate action). Workspace and Project windows are `WindowGroup(for:)`
/// scenes keyed by domain id, so opening an already-open id focuses its window instead
/// of spawning a duplicate (PRD §7.1).
/// Both restore on relaunch (intent, not just geometry — PRD §16.2): the restored view
/// reloads against the shared store and shows a 404 surface for a deleted id.
@main
struct SupersetApp: App {
    @State private var auth: AuthController
    @State private var store: WorkspaceStore
    @State private var lock: LockController
    @State private var openWindows = OpenWindowsModel()
    @State private var appSettings: AppSettingsStore
    @State private var onboarding: OnboardingStore
    @State private var metrics: SessionMetrics
    @Environment(\.scenePhase) private var scenePhase

    /// Retained for the app's lifetime so its MetricKit subscription stays registered
    /// (ADR-0007). It has no UI; a plain stored reference keeps it alive.
    private let crashReporter: CrashReporter

    init() {
        let uiTest = UITestSupport.isEnabled
        let auth = uiTest ? UITestSupport.makeAuthController() : AuthController()
        _auth = State(initialValue: auth)

        // On-device observability from day one (ADR-0007): one telemetry sink feeds both
        // the MetricKit crash reporter and the lifecycle product metrics (M1/M3/M4/M-Host).
        let telemetry = Telemetry.live()
        crashReporter = CrashReporter(telemetry: telemetry)
        _metrics = State(initialValue: SessionMetrics(telemetry: telemetry))
        // Under UI test the store is seeded with sample workspaces (no network), so a row
        // exists to tap; production wires the cloud-backed provider/lifecycle.
        let store = uiTest ? WorkspaceStore.sample() : WorkspaceStore(
            provider: auth.makeWorkspaceListProvider(),
            lifecycle: auth.makeWorkspaceLifecycleClient(),
            cache: FileWorkspaceListCache()
        )
        _store = State(initialValue: store)

        // UI test mode pre-grants dictation (so the mic toggle is reachable) and skips the
        // first-run tour (so it doesn't cover the workspace list).
        let appSettings = AppSettingsStore()
        let onboarding = OnboardingStore()
        if uiTest {
            appSettings.dictationEnabled = true
            onboarding.isPresented = false
        }
        _appSettings = State(initialValue: appSettings)
        _onboarding = State(initialValue: onboarding)
        // The controller owns the sign-out cache reset so it runs on every sign-out
        // path — including a sign-out from Settings while the command-center window
        // (the old observer's host) is closed.
        auth.onSignedOut = { [store] in store.reset() }
        // The Optic ID gate sits over every signed-in window and shares the relay
        // credential with `auth`, so locking seals the RCE-grade JWT app-wide (ADR-0008).
        // Under UI test the gate degrades to unlocked (the Simulator can't answer an Optic
        // ID prompt), so the smoke flow reaches the signed-in content.
        _lock = State(initialValue: uiTest
            ? UITestSupport.makeLockController(relay: auth)
            : LockController(relay: auth))
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView(auth: auth, store: store, openWindows: openWindows)
                .environment(onboarding)
                .environment(metrics)
                .lockGate(lock: lock, auth: auth)
                .preferredColorScheme(appSettings.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 820)
        // M4/M-Host: a session opens on first activation and closes on background,
        // independent of which window is frontmost (PRD §17). The app-level `scenePhase`
        // is the aggregate across scenes, so `.background` here means a true app background
        // (headset removed / app suspended), not a single window closing — which is exactly
        // when the Optic ID gate must re-engage (ADR-0008). Driving the lock from here keeps
        // closing one window from re-locking the others.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                metrics.sessionDidStart()
            case .background:
                metrics.sessionDidEnd()
                if auth.status == .signedIn {
                    // Clear the cached relay JWT inline so the RCE-grade token is gone before
                    // the OS can suspend the app; the awaited `lock()` runs in a `Task` that
                    // may not be scheduled in time. `lock()` then seals re-minting until the
                    // next Optic ID pass (ADR-0008).
                    auth.dropRelayToken()
                    Task { await lock.lock() }
                }
            default: break
            }
        }

        WindowGroup(id: WorkspaceScene.windowID, for: Workspace.ID.self) { $workspaceID in
            WorkspaceWindowView(workspaceID: workspaceID, store: store, auth: auth)
                .environment(openWindows)
                .environment(appSettings)
                .environment(metrics)
                .lockGate(lock: lock, auth: auth)
                .preferredColorScheme(appSettings.appearance.colorScheme)
        }
        .defaultSize(width: 720, height: 720)
        .restorationBehavior(.automatic)

        WindowGroup(id: ProjectScene.windowID, for: Project.ID.self) { $projectID in
            ProjectWindowView(projectID: projectID, store: store)
                .environment(openWindows)
                .lockGate(lock: lock, auth: auth)
                .preferredColorScheme(appSettings.appearance.colorScheme)
        }
        .defaultSize(width: 640, height: 720)
        .restorationBehavior(.automatic)

        WindowGroup(id: SettingsScene.windowID) {
            SettingsView(auth: auth, store: store)
                .environment(appSettings)
                .environment(onboarding)
                .lockGate(lock: lock, auth: auth)
                .preferredColorScheme(appSettings.appearance.colorScheme)
        }
        .defaultSize(width: 560, height: 720)
        .restorationBehavior(.automatic)

        WindowGroup(id: DebugScene.windowID) {
            DebugDumpView(store: store)
                .lockGate(lock: lock, auth: auth)
                .preferredColorScheme(appSettings.appearance.colorScheme)
        }
        .defaultSize(width: 560, height: 720)
    }
}
