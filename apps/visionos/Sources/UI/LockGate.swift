import SwiftUI

/// Wraps a scene's content in the Optic ID gate (ADR-0008). Applied to every window so
/// the lock is app-wide: signed-in content is covered by `LockView` whenever the shared
/// `LockController` is engaged, and the credential is sealed on background.
///
/// The gate only acts when signed in — a signed-out window shows its own sign-in surface
/// untouched. Locking keys on `.background` (the whole app leaving the foreground), not a
/// single window losing focus (`.inactive`), so defocusing one of several windows never
/// locks the others.
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
                switch phase {
                case .background:
                    // Drop the cached relay JWT inline so the RCE-grade token is gone
                    // before the OS can suspend the app — the awaited `lock()` runs in a
                    // Task that may not be scheduled in time. `lock()` then seals
                    // re-minting until the next Optic ID pass (ADR-0008).
                    auth.dropRelayToken()
                    Task { await lock.lock() }
                case .active:
                    if lock.isLocked {
                        Task { await lock.authenticate() }
                    }
                default:
                    break
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
