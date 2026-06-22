import SwiftUI

/// Root window content — the command-center / switcher (PRD §7.1). Renders the active
/// adapter's `workspaceList` pane over the shared, cloud-backed `WorkspaceStore`, which
/// is polled while any window is visible and paused when the app backgrounds (ADR-0004).
///
/// Three ornaments host the chrome (PRD §9): a leading-edge icon rail (`RootRailView`,
/// ADR-0011) that switches the content pane and opens the create sheet, a bottom adapter
/// switcher whose flip re-renders the *same* store (the M0 renderer seam), and a
/// window-controls menu carrying the interaction-model flag (§10) and the explicit
/// "consolidate windows" action.
struct RootView: View {
    @Bindable var store: WorkspaceStore
    let auth: AuthController
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
    @State private var railSelection: RailDestination = .workspaces
    @State private var isCreating = false
    /// The org menu's cloud read model (session + memberships). Owned per-window like
    /// Settings', so the rail can switch the active org without the Settings window open.
    @State private var settings: SettingsModel

    init(store: WorkspaceStore, auth: AuthController) {
        self.store = store
        self.auth = auth
        _settings = State(initialValue: SettingsModel(api: auth.makeAPIClient()))
    }

    var body: some View {
        NavigationStack {
            railContent
                .navigationTitle(railSelection.title)
        }
        .ornament(attachmentAnchor: .scene(.leading)) {
            RootRailView(
                selection: $railSelection,
                canCreateWorkspace: store.supportsLifecycle,
                organizations: settings.organizations,
                activeOrganizationID: settings.activeOrganizationID,
                activeOrganizationName: settings.activeOrganizationName,
                isSwitchingOrganization: settings.isSwitchingOrganization,
                paidPlan: store.paidPlan,
                onNewWorkspace: { isCreating = true },
                onSwitchOrganization: switchOrganization,
                onOpenSettings: { openWindow(id: SettingsScene.windowID) },
                onSignOut: { auth.signOut() }
            )
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            bottomControls
        }
        .sheet(isPresented: $isCreating) {
            WorkspaceCreateView(store: store)
        }
        .task { await settings.load() }
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

    /// Switch the session's active org from the rail menu, then refresh the shared list so
    /// the tree reflects the new org without waiting for the next poll tick (mirrors the
    /// Settings org flow).
    private func switchOrganization(to id: String) {
        Task {
            await settings.switchOrganization(to: id)
            if settings.switchError == nil { await store.refresh() }
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

    /// The content pane for the selected rail item. Workspaces renders the active
    /// adapter's list (the collapsible project tree lands in a later slice); Automations
    /// and Tasks & PRs are placeholders until wired.
    @ViewBuilder
    private var railContent: some View {
        switch railSelection {
        case .workspaces:
            registry.activeAdapter.view(for: .workspaceList, store: store)
        case .automations, .tasks:
            ContentUnavailableView(
                railSelection.title,
                systemImage: railSelection.systemImage,
                description: Text("Coming soon.")
            )
        }
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
