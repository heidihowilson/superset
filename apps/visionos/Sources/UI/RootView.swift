import SwiftUI

/// Root window content — the command-center / switcher (PRD §7.1). Renders the active
/// adapter's `workspaceList` pane over the shared, cloud-backed `WorkspaceStore`, which
/// is polled while any window is visible and paused when the app backgrounds (ADR-0004).
///
/// Three ornaments host the chrome (PRD §9): a leading-edge Workspace switcher that
/// opens/focuses Workspace windows, a bottom adapter switcher whose flip re-renders the
/// *same* store (the M0 renderer seam), and a window-controls menu carrying the
/// interaction-model flag (§10) and the explicit "consolidate windows" action.
struct RootView: View {
    @Bindable var store: WorkspaceStore
    @State private var registry = AdapterRegistry(adapters: [
        NativeWorkspaceAdapter(),
        DebugListAdapter(),
    ])
    @Environment(InteractionModelRegistry.self) private var models
    @Environment(OpenWindowsModel.self) private var openWindows
    @Environment(SessionMetrics.self) private var metrics
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneActive = false

    var body: some View {
        NavigationStack {
            registry.activeAdapter.view(for: .workspaceList, store: store)
                .navigationTitle("Superset")
        }
        .ornament(attachmentAnchor: .scene(.leading)) {
            WorkspaceSwitcherView(store: store)
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            bottomControls
        }
        .onAppear {
            store.beginPolling()
            syncForeground(scenePhase)
            // M1: the Workspace browser is the first meaningful Workspace surface
            // (PRD §17). Once-only — guarded inside `SessionMetrics`.
            metrics.markFirstMeaningfulView()
        }
        .onDisappear {
            syncForeground(.background)
            store.endPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            syncForeground(phase)
        }
    }

    /// Report this scene's active-ness to the shared store, contributing exactly one to
    /// its active-scene count and keeping register/unregister balanced across phase
    /// changes and window close (so one inactive window can't pause polling for others).
    private func syncForeground(_ phase: ScenePhase) {
        let active = phase == .active
        guard active != sceneActive else { return }
        sceneActive = active
        if active { store.sceneBecameActive() } else { store.sceneResignedActive() }
    }

    private var bottomControls: some View {
        HStack(spacing: 16) {
            adapterSwitcher
            Divider().frame(height: 28)
            windowMenu
            settingsButton
        }
        .padding()
        .glassBackgroundEffect()
    }

    private var settingsButton: some View {
        Button {
            openWindow(id: SettingsScene.windowID)
        } label: {
            Label("Settings", systemImage: "gearshape")
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
    }

    private var windowMenu: some View {
        Menu {
            Picker("Interaction Model", selection: activeModelBinding) {
                ForEach(models.models) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .pickerStyle(.inline)

            if openWindows.openWindowCount > 0 {
                Button("Consolidate Windows", systemImage: "rectangle.on.rectangle.slash") {
                    WindowRouter.consolidate(except: nil, openWindows: openWindows, dismissWindow: dismissWindow)
                }
            }
        } label: {
            Label("Windows", systemImage: "macwindow.on.rectangle")
        }
    }

    private var activeModelBinding: Binding<String> {
        Binding(
            get: { models.activeModelID },
            set: { models.activate($0) }
        )
    }
}
