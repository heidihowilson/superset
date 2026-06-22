import SwiftUI

/// The Settings window scene id. A plain `WindowGroup` (no domain value) — one shared
/// Settings window, opened/focused from the command-center chrome (PRD §7.1).
enum SettingsScene {
    static let windowID = "settings"
}

/// Read-mostly Settings (PRD §7.2). Editable: the active organization (cloud), a
/// preferred default model, and the device-local appearance/dictation/notification
/// prefs, plus sign-out. Read-only: account, plan (billing), hosts (with a live
/// host-online indicator), and projects. Host/macOS-specific surfaces are cut (§7.2).
///
/// Drives the shared `WorkspaceStore`'s poll while visible (like `RootView`) so the
/// host-online indicator stays live even when Settings is the only open window, and
/// observes a `SettingsModel` for the cloud account/org reads.
struct SettingsView: View {
    let auth: AuthController
    @Bindable var store: WorkspaceStore

    @Environment(AppSettingsStore.self) private var appSettings
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: SettingsModel
    @State private var sceneActive = false

    init(auth: AuthController, store: WorkspaceStore) {
        self.auth = auth
        self.store = store
        _model = State(initialValue: SettingsModel(api: auth.makeAPIClient()))
    }

    var body: some View {
        @Bindable var appSettings = appSettings
        NavigationStack {
            Form {
                organizationSection

                Section("Appearance") {
                    Picker("Theme", selection: $appSettings.appearance) {
                        ForEach(AppSettingsStore.Appearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                }

                Section("Model") {
                    Picker("Preferred model", selection: $appSettings.preferredModelID) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.models) { chatModel in
                            Text(chatModel.name).tag(Optional(chatModel.id))
                        }
                    }
                }

                Section {
                    Toggle("Voice dictation", isOn: $appSettings.dictationEnabled)
                    Toggle("In-app notifications", isOn: $appSettings.notificationsEnabled)
                } header: {
                    Text("Input & Notifications")
                } footer: {
                    Text("These preferences are stored on this device.")
                }

                Section {
                    Button("Show Welcome Tour") {
                        // The tour presents over the command-center window (FR-ONB), so
                        // close Settings to surface it unobstructed there.
                        onboarding.replay()
                        dismissWindow(id: SettingsScene.windowID)
                    }
                } header: {
                    Text("Onboarding")
                } footer: {
                    Text("Replay the first-run walkthrough of gaze, the switcher, and Host status.")
                }

                accountSection
                hostCredentialSection
                planSection
                hostsSection
                projectsSection

                Section {
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                        dismissWindow(id: SettingsScene.windowID)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
        .frame(minWidth: 480, minHeight: 600)
        .task { await model.load() }
        .onAppear {
            store.beginPolling()
            syncForeground(scenePhase)
        }
        .onDisappear {
            syncForeground(.background)
            store.endPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            syncForeground(phase)
        }
    }

    // MARK: Editable — organization (cloud)

    private var organizationSection: some View {
        Section("Organization") {
            switch model.loadState {
            case .idle, .loading:
                ProgressView()
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .loaded:
                if model.organizations.isEmpty {
                    Text("No organizations").foregroundStyle(.secondary)
                } else {
                    Picker("Active organization", selection: organizationBinding) {
                        ForEach(model.organizations) { org in
                            Text(org.name).tag(org.id)
                        }
                    }
                    .disabled(model.isSwitchingOrganization)
                }
                if model.isSwitchingOrganization {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Switching…").foregroundStyle(.secondary)
                    }
                }
                if let switchError = model.switchError {
                    Label(switchError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Selecting a row switches the session's active org, then refreshes the shared list
    /// so the browser reflects the new org without waiting for the next poll tick.
    private var organizationBinding: Binding<String> {
        Binding(
            get: { model.activeOrganizationID ?? model.organizations.first?.id ?? "" },
            set: { newID in
                Task {
                    await model.switchOrganization(to: newID)
                    if model.switchError == nil { await store.refresh() }
                }
            }
        )
    }

    // MARK: Read-only

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Email", value: model.session?.userEmail ?? "—")
            LabeledContent("Organization", value: model.activeOrganizationName ?? "—")
        }
    }

    /// Verify the bearer session can mint the relay JWT host-service-over-relay calls
    /// present (PRD §13). Moved here from the command-center ornament; the minted token is
    /// never shown.
    private var hostCredentialSection: some View {
        Section {
            Button("Verify host credential") {
                Task { await model.mintRelayCredential() }
            }
            .disabled(model.relayProbe == .running)
            relayStatus
        } header: {
            Text("Host Credential")
        } footer: {
            Text("Mints the relay token your hosts present. The token is never shown.")
        }
    }

    @ViewBuilder
    private var relayStatus: some View {
        switch model.relayProbe {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("Verifying…").foregroundStyle(.secondary)
            }
        case .minted:
            Label("Relay credential minted", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var planSection: some View {
        Section {
            LabeledContent("Plan", value: planLabel)
        } header: {
            Text("Billing")
        } footer: {
            Text("Billing is managed on the Superset web app.")
        }
    }

    private var planLabel: String {
        switch store.paidPlan {
        case .some(true): "Active"
        case .some(false): "Free"
        case .none: "Unknown"
        }
    }

    private var hostsSection: some View {
        Section("Hosts") {
            if store.hosts.isEmpty {
                Text("No hosts").foregroundStyle(.secondary)
            } else {
                ForEach(sortedHosts) { host in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(host.online ? Color.green : Color.secondary)
                            .frame(width: 10, height: 10)
                        Text(host.name)
                        Spacer(minLength: 0)
                        Text(host.online ? "Online" : "Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(host.name), \(host.online ? "online" : "offline")")
                }
            }
        }
    }

    private var sortedHosts: [HostSummary] {
        store.hosts.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var projectsSection: some View {
        Section("Projects") {
            if store.projects.isEmpty {
                Text("No projects").foregroundStyle(.secondary)
            } else {
                ForEach(store.projects) { project in
                    Text(project.name)
                }
            }
        }
    }

    /// Report this scene's active-ness to the shared store so the host-online indicator
    /// polls while Settings is visible — the same balanced register/unregister `RootView`
    /// uses so one inactive window can't pause the shared poll for others.
    private func syncForeground(_ phase: ScenePhase) {
        let active = phase == .active
        guard active != sceneActive else { return }
        sceneActive = active
        if active { store.sceneBecameActive() } else { store.sceneResignedActive() }
    }
}

#Preview {
    SettingsView(auth: AuthController(), store: .sample())
        .environment(AppSettingsStore())
}
