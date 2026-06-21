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

    func body(content: Content) -> some View {
        content
            .overlay {
                if signedIn && lock.isLocked {
                    LockView(lock: lock)
                }
            }
            .onAppear {
                // Launch / first paint: seal the relay and demand Optic ID before any
                // restored window can reveal content (ADR-0008 "Optic ID on launch").
                if signedIn && lock.isLocked {
                    lock.lock()
                    Task { await lock.authenticate() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard signedIn else { return }
                switch phase {
                case .background:
                    lock.lock()
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
                    lock.lock()
                    Task { await lock.authenticate() }
                case (_, .signedIn):
                    // A fresh OAuth sign-in already proved the owner in the browser —
                    // skip the redundant Optic ID prompt.
                    lock.unlock()
                case (_, .signedOut):
                    // Re-arm the gate so the next sign-in / relaunch requires Optic ID.
                    lock.lock()
                default:
                    break
                }
            }
    }
}

extension View {
    /// Apply the app-wide Optic ID gate to a scene's root content.
    func lockGate(lock: LockController, auth: AuthController) -> some View {
        modifier(LockGate(lock: lock, auth: auth))
    }
}
