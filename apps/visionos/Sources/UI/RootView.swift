import SwiftUI

/// Root window content — the command-center / switcher (PRD §7.1). Renders the active
/// adapter's `workspaceList` pane over the shared, cloud-backed `WorkspaceStore`, which
/// is polled while any window is visible and paused when the app backgrounds (ADR-0004).
///
/// Two ornaments host the chrome (PRD §9, ADR-0011): a leading-edge icon rail
/// (`RootRailView`) that switches the content pane, opens the create sheet, and opens
/// Settings, and a bottom window-controls menu carrying the explicit "consolidate
/// windows" action.
struct RootView: View {
    @Bindable var store: WorkspaceStore
    let auth: AuthController
    @State private var registry = AdapterRegistry(adapters: [
        NativeWorkspaceAdapter(),
    ])
    @Environment(OpenWindowsModel.self) private var openWindows
    @Environment(SessionMetrics.self) private var metrics
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
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
        .alert(
            "Couldn't complete that",
            isPresented: lifecycleErrorBinding,
            presenting: store.lifecycleError
        ) { _ in
            Button("OK") { store.clearLifecycleError() }
        } message: { message in
            Text(message)
        }
        .task { await settings.load() }
        .scenePollingMembership(store: store)
        .onAppear {
            // M1: the Workspace browser is the first meaningful Workspace surface
            // (PRD §17). Once-only — guarded inside `SessionMetrics`.
            metrics.markFirstMeaningfulView()
        }
    }

    /// Presentation binding for the shared store's lifecycle-error alert. A failed create from
    /// the rail '+' surfaces here — `WorkspaceCreateView` keeps its sheet open on failure
    /// (it dismisses only when `lifecycleError == nil`), and the list's own alert lives outside
    /// this window's tree, so without this the failure is a silent no-op. Dismissing clears the
    /// error, which lets the sheet's success guard dismiss on the next attempt.
    private var lifecycleErrorBinding: Binding<Bool> {
        Binding(
            get: { store.lifecycleError != nil },
            set: { if !$0 { store.clearLifecycleError() } }
        )
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

    /// The content pane for the selected rail item. Workspaces renders the active
    /// adapter's list (the collapsible project tree); Automations and Tasks & PRs are
    /// placeholders until wired.
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
        windowMenu
            .padding()
            .glassBackgroundEffect()
    }

    private var windowMenu: some View {
        Menu {
            if openWindows.openWindowCount > 0 {
                Button("Consolidate Windows", systemImage: "rectangle.on.rectangle.slash") {
                    WindowRouter.consolidate(openWindows: openWindows, dismissWindow: dismissWindow)
                }
            } else {
                Text("No open windows")
            }
        } label: {
            Label("Windows", systemImage: "macwindow.on.rectangle")
        }
    }
}
