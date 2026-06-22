import SwiftUI

/// Identifiers for the Workspace window scene, shared by the App (which declares the
/// `WindowGroup`) and the switcher/list (which open it by Workspace id).
enum WorkspaceScene {
    static let windowID = "workspace"
}

/// The leading-ornament workspace nav (PRD §9: chrome lives in ornaments, not inline
/// toolbars). Mirrors the desktop sidebar's hierarchy so the two clients feel like one
/// product: an org-switcher header (initials + active-org name + plan badge + switch)
/// above the primary nav rows — Workspaces, Automations, Tasks & PRs, New Workspace —
/// with the cloud-listed Workspaces grouped by Project beneath the live Workspaces row.
/// Automations and Tasks & PRs are present in the hierarchy but inert until wired.
/// Tapping a Workspace selects it and opens/focuses its Workspace window; because the
/// window is keyed by Workspace id, re-tapping focuses the existing window.
struct WorkspaceSwitcherView: View {
    @Bindable var store: WorkspaceStore
    let auth: AuthController

    @Environment(InteractionModelRegistry.self) private var models
    @Environment(OpenWindowsModel.self) private var openWindows
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// Cloud account/org reads for the header. A read-only reuse of the same session/org
    /// surface Settings drives — switching the active org needs no re-auth (ADR-0005).
    @State private var orgModel: SettingsModel
    @State private var isCreating = false

    init(store: WorkspaceStore, auth: AuthController) {
        self.store = store
        self.auth = auth
        _orgModel = State(initialValue: SettingsModel(api: auth.makeAPIClient()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            orgHeader

            Divider()

            NavRow(title: "Workspaces", systemImage: "square.stack.3d.up", isActive: true) {}
            NavRow(title: "Automations", systemImage: "clock", comingSoon: true)
            NavRow(title: "Tasks & PRs", systemImage: "list.clipboard", comingSoon: true)
            NavRow(
                title: "New Workspace",
                systemImage: "plus",
                isEnabled: store.supportsLifecycle
            ) {
                isCreating = true
            }

            Divider()

            workspaceList
        }
        .padding()
        .frame(width: 260, height: 520)
        .glassBackgroundEffect()
        .task { await orgModel.load() }
        .sheet(isPresented: $isCreating) {
            WorkspaceCreateView(store: store)
        }
    }

    // MARK: Org-switcher header

    private var orgHeader: some View {
        Menu {
            if orgModel.organizations.isEmpty {
                Text("No organizations")
            } else {
                Picker("Organization", selection: organizationBinding) {
                    ForEach(orgModel.organizations) { org in
                        Text(org.name).tag(org.id)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            HStack(spacing: 10) {
                Text(orgInitials)
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(.tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                Text(orgName)
                    .font(.headline)
                    .lineLimit(1)
                planBadge
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(orgModel.isSwitchingOrganization)
        .accessibilityLabel("Organization \(orgName), switch organization")
    }

    /// Selecting a row switches the session's active org, then refreshes the shared list
    /// so the browser reflects the new org without waiting for the next poll tick — the
    /// same flow as the Settings organization picker.
    private var organizationBinding: Binding<String> {
        Binding(
            get: { orgModel.activeOrganizationID ?? orgModel.organizations.first?.id ?? "" },
            set: { newID in
                Task {
                    await orgModel.switchOrganization(to: newID)
                    if orgModel.switchError == nil { await store.refresh() }
                }
            }
        )
    }

    private var orgName: String {
        orgModel.activeOrganizationName ?? "Organization"
    }

    private var orgInitials: String {
        let parts = orgName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        return letters.isEmpty ? "•" : String(letters).uppercased()
    }

    /// The plan badge, mirroring the desktop header's uppercase plan tag: a paid org gets
    /// the highlighted accent tag, a free org a muted one. An undeterminable plan
    /// (`paidPlan == nil`) shows nothing rather than guessing.
    @ViewBuilder
    private var planBadge: some View {
        if let plan = store.paidPlan {
            Text(plan ? "PRO" : "FREE")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    plan ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.3)),
                    in: Capsule()
                )
                .foregroundStyle(plan ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
    }

    // MARK: Workspaces

    private var workspaceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.groups) { group in
                    if !group.workspaces.isEmpty {
                        Text(group.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(group.workspaces) { workspace in
                            Button {
                                WindowRouter.openWorkspace(
                                    workspace.id,
                                    store: store,
                                    models: models,
                                    openWindows: openWindows,
                                    openWindow: openWindow,
                                    dismissWindow: dismissWindow
                                )
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(workspace.status.tint)
                                        .frame(width: 10, height: 10)
                                        .accessibilityLabel(workspace.status.label)
                                    Text(workspace.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A primary nav row in the leading sidebar: an SF Symbol + title, styled to read as the
/// active surface, a tappable destination, or an inert "Soon" item that holds its place
/// in the hierarchy without offering dead navigation.
private struct NavRow: View {
    let title: String
    let systemImage: String
    var isActive = false
    var comingSoon = false
    var isEnabled = true
    var action: () -> Void = {}

    private var interactive: Bool { isEnabled && !comingSoon }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if comingSoon {
                    Text("Soon")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout.weight(isActive ? .semibold : .regular))
            .foregroundStyle(interactive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(
                isActive ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
        .accessibilityHint(comingSoon ? "Coming soon" : "")
    }
}
