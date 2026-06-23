import SwiftUI

/// Enrolls a window scene in the shared `WorkspaceStore` poll for its visible lifetime and
/// reports its foreground/background phase, so the store's reference-counted poll runs while
/// any window is visible and active and pauses otherwise (ADR-0004). Every content-window
/// root carried a hand-copied `@State sceneActive` + `syncForeground` + the same
/// onAppear/onDisappear/onChange trio; this collapses that into one modifier so the
/// register/unregister balance lives in exactly one place.
///
/// A stable per-scene `token` identifies this window to the store's idempotent membership
/// sets, so SwiftUI's occasionally-duplicated lifecycle callbacks can't over- or
/// under-count the shared poll. `onActiveChange` fires on each foreground⟷background
/// boundary (active first), letting a window layer its own per-active work — e.g. the
/// Workspace window's focus-dwell metrics and watch-poll gating — without re-implementing
/// the trio.
struct ScenePollingMembership: ViewModifier {
    let store: WorkspaceStore
    var onActiveChange: ((Bool) -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var token = UUID()
    @State private var sceneActive = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                store.beginPolling(token: token)
                syncForeground(scenePhase)
            }
            .onDisappear {
                syncForeground(.background)
                store.endPolling(token: token)
            }
            .onChange(of: scenePhase) { _, phase in
                syncForeground(phase)
            }
    }

    /// Report this scene's active-ness to the shared store, contributing exactly one to its
    /// active-scene membership and keeping register/unregister balanced across phase changes
    /// and window close (so one inactive window can't pause the poll for others).
    private func syncForeground(_ phase: ScenePhase) {
        let active = phase == .active
        guard active != sceneActive else { return }
        sceneActive = active
        if active { store.sceneBecameActive(token: token) } else { store.sceneResignedActive(token: token) }
        onActiveChange?(active)
    }
}

extension View {
    /// Enroll this window root in the shared poll for its visible, foregrounded lifetime.
    /// `onActiveChange` runs on each foreground⟷background boundary for window-local work.
    func scenePollingMembership(
        store: WorkspaceStore,
        onActiveChange: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(ScenePollingMembership(store: store, onActiveChange: onActiveChange))
    }
}
