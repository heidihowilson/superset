import SwiftUI

/// Root window content. Renders the active adapter's `workspaceList` pane over the
/// shared, cloud-backed `WorkspaceStore`. The store is polled while this view is
/// visible and paused when it is hidden or the scene backgrounds (ADR-0004).
///
/// Two ornaments host the chrome (PRD §9): a leading-edge Workspace switcher that
/// opens/focuses Workspace windows, and a bottom adapter switcher whose flip
/// re-renders the *same* store, demonstrating the M0 renderer seam.
struct RootView: View {
    @Bindable var store: WorkspaceStore
    @State private var registry = AdapterRegistry(adapters: [
        NativeWorkspaceAdapter(),
        DebugListAdapter(),
    ])
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            registry.activeAdapter.view(for: .workspaceList, store: store)
                .navigationTitle("Superset")
        }
        .ornament(attachmentAnchor: .scene(.leading)) {
            WorkspaceSwitcherView(store: store)
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            adapterSwitcher
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.startPolling()
            } else {
                store.stopPolling()
            }
        }
        .onChange(of: store.selectedWorkspaceID) { _, selected in
            if let selected {
                openWindow(id: WorkspaceScene.windowID, value: selected)
            }
        }
    }

    private var adapterSwitcher: some View {
        HStack(spacing: 12) {
            ForEach(registry.adapters.indices, id: \.self) { index in
                let adapter = registry.adapters[index]
                Button(adapter.displayName) {
                    registry.activate(adapter.id)
                }
                .buttonStyle(.borderedProminent)
                .tint(adapter.id == registry.activeAdapterID ? .accentColor : .gray)
            }
        }
        .padding()
        .glassBackgroundEffect()
    }
}
