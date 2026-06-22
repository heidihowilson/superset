import SwiftUI

/// Wraps a scene's content in the Optic ID gate (ADR-0008). Applied to every window so
/// the lock is app-wide: signed-in content is covered by `LockView` whenever the shared
/// `LockController` is engaged.
///
/// The gate only acts when signed in — a signed-out window shows its own sign-in surface
/// untouched. It re-runs Optic ID when a window foregrounds while locked, but it never
/// *engages* the lock from its own `scenePhase`: closing or backgrounding a single window
/// fires that scene's `.background` even while other windows stay visible, so a per-scene
/// lock here would re-lock every window when one closes. Locking is instead driven from the
/// app-level `scenePhase` in `SupersetApp`, whose aggregate phase reaches `.background` only
/// on a true app background (headset removed / app suspended).
private struct LockGate: ViewModifier {
    @Bindable var lock: LockController
    let auth: AuthController

    @Environment(\.scenePhase) private var scenePhase

    private var signedIn: Bool { auth.status == .signedIn }

    private var loading: Bool { auth.status == .loading }

    func body(content: Content) -> some View {
        content
            .overlay {
                if loading {
                    // A restored Workspace/Project window paints cached signed-in content
                    // before the Keychain read resolves. Cover it until the gate knows
                    // whether to demand Optic ID (signed in) or reveal sign-in (signed out)
                    // — ADR-0008 "Optic ID on launch". No unlock affordance here so the
                    // owner can't bypass the gate before auth resolves.
                    LaunchCoverView()
                } else if signedIn && lock.isLocked {
                    LockView(lock: lock)
                }
            }
            .onAppear {
                // A restored content window can appear before the auth root reads the
                // Keychain — and the main window that normally calls `restore()` may not
                // itself have been restored. Kick the restore so the launch cover resolves.
                if loading {
                    auth.restore()
                }
                // Launch / first paint with a session already restored: seal the relay and
                // demand Optic ID before any restored window can reveal content (ADR-0008).
                if signedIn && lock.isLocked {
                    Task {
                        await lock.lock()
                        await lock.authenticate()
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard signedIn else { return }
                // Only re-authenticate on foreground; engaging the lock is the app-level
                // scene's job (`SupersetApp`) so closing one window can't lock the rest.
                if phase == .active, lock.isLocked {
                    Task { await lock.authenticate() }
                }
            }
            .onChange(of: auth.status) { old, new in
                switch (old, new) {
                case (.loading, .signedIn):
                    // Launch restored a stored session — demand Optic ID before the
                    // workspaces appear (ADR-0008 "Optic ID on launch").
                    Task {
                        await lock.lock()
                        await lock.authenticate()
                    }
                case (_, .signedIn):
                    // A fresh OAuth sign-in already proved the owner in the browser —
                    // skip the redundant Optic ID prompt.
                    Task { await lock.unlock() }
                case (_, .signedOut):
                    // Re-arm the gate so the next sign-in / relaunch requires Optic ID.
                    Task { await lock.lock() }
                default:
                    break
                }
            }
    }
}

/// Non-interactive launch cover. Hides a restored window's cached content while auth is
/// still resolving, matching `LockView`'s full-scene material so the locked and launching
/// states read the same. Carries no unlock control — the gate decides the next surface.
private struct LaunchCoverView: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .ignoresSafeArea()
    }
}

extension View {
    /// Apply the app-wide Optic ID gate to a scene's root content.
    func lockGate(lock: LockController, auth: AuthController) -> some View {
        modifier(LockGate(lock: lock, auth: auth))
    }
}
