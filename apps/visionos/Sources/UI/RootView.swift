import SwiftUI

/// Root window content. Owns the single shared `WorkspaceStore` and the
/// `AdapterRegistry`, and renders the active adapter's `workspaceList` pane. The
/// bottom ornament hosts a runtime adapter switcher (PRD §9: chrome lives in
/// ornaments, not inline toolbars) — flipping it re-renders the *same* store,
/// demonstrating the M0 seam.
struct RootView: View {
    @State private var store = WorkspaceStore.sample()
    @State private var registry = AdapterRegistry(adapters: [
        NativeWorkspaceAdapter(),
        DebugListAdapter(),
    ])

    var body: some View {
        NavigationStack {
            registry.activeAdapter.view(for: .workspaceList, store: store)
                .navigationTitle("Superset")
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            adapterSwitcher
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
