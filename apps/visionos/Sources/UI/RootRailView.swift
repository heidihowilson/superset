import SwiftUI

/// The content surfaces the icon rail switches between in the root window. Each maps to a
/// rail item; the selected one fills the content pane. `workspaces` is the default and
/// renders the collapsible project tree; `automations` and `tasks` are placeholder panes
/// until wired.
enum RailDestination: String, CaseIterable, Identifiable {
    case workspaces
    case automations
    case tasks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspaces: "Workspaces"
        case .automations: "Automations"
        case .tasks: "Tasks & PRs"
        }
    }

    var systemImage: String {
        switch self {
        case .workspaces: "square.stack.3d.up"
        case .automations: "clock"
        case .tasks: "list.clipboard"
        }
    }
}

/// The leading-edge icon rail (IA V1.1 revision, ADR-0011). Replaces the wide 260pt
/// `WorkspaceSwitcherView` ornament with a slim, ~one-icon-wide rail mirroring the desktop
/// left nav, top to bottom: ⬡ Org · ▣ Workspaces · ◷ Automations · ▤ Tasks & PRs · ＋ New.
///
/// Icons only by default — the title is revealed on hover/gaze via `.help()` and a hover
/// effect. Selecting a destination swaps the content pane in `RootView`; ⚙ Settings (below
/// Tasks & PRs) opens the Settings window; ＋ opens the create sheet; and ⬡ Org opens the
/// org menu: the active org + the membership list (tap to switch), a divider, and Sign Out.
struct RootRailView: View {
    @Binding var selection: RailDestination
    let canCreateWorkspace: Bool
    /// The org menu's membership list and active selection (the `SettingsModel` org flow).
    let organizations: [OrganizationSummary]
    let activeOrganizationID: String?
    let activeOrganizationName: String?
    let isSwitchingOrganization: Bool
    /// The active org's plan, surfaced as the rail affordance's badge (`true` → Pro).
    let paidPlan: Bool?
    var onNewWorkspace: () -> Void
    var onSwitchOrganization: (String) -> Void
    var onOpenSettings: () -> Void
    var onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            orgItem

            Divider().frame(width: 40)

            ForEach(RailDestination.allCases) { destination in
                RailItem(
                    title: destination.title,
                    systemImage: destination.systemImage,
                    isSelected: selection == destination
                ) {
                    selection = destination
                }
            }

            // Settings sits directly below Tasks & PRs (ADR-0011): a rail item, not an
            // Org-menu entry. It opens its own window rather than switching the pane.
            RailItem(
                title: "Settings",
                systemImage: "gearshape",
                action: onOpenSettings
            )

            Divider().frame(width: 40)

            RailItem(
                title: "New Workspace",
                systemImage: "plus",
                isEnabled: canCreateWorkspace,
                action: onNewWorkspace
            )
        }
        .padding(.vertical, 16)
        .frame(width: 72)
        .glassBackgroundEffect()
    }

    /// ⬡ Org — the IA's org menu (mirrors desktop): switch active org, then Sign Out.
    /// Settings moved to its own rail item (ADR-0011). The rail affordance is icon-first
    /// (active-org initials + a plan badge); the org name and plan are revealed on hover.
    private var orgItem: some View {
        Menu {
            ForEach(organizations) { org in
                orgRow(org)
            }

            Divider()

            Button(role: .destructive, action: onSignOut) {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            orgLabel
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(orgHelp)
        .accessibilityLabel(orgAccessibilityLabel)
    }

    /// One membership row: a checkmark marks the active org, which also carries the plan
    /// badge (the IA shows "✓ acme  PRO"). Disabled while a switch is in flight.
    @ViewBuilder
    private func orgRow(_ org: OrganizationSummary) -> some View {
        let isActive = org.id == activeOrganizationID
        Button { onSwitchOrganization(org.id) } label: {
            if isActive {
                Label(orgRowTitle(org.name), systemImage: "checkmark")
            } else {
                Text(org.name)
            }
        }
        .disabled(isSwitchingOrganization)
    }

    /// The active-org row's title, suffixed with the plan badge on a paid plan.
    private func orgRowTitle(_ name: String) -> String {
        paidPlan == true ? "\(name) · PRO" : name
    }

    /// The rail affordance: the active org's initials (a hexagon before any org loads),
    /// badged when on a paid plan.
    private var orgLabel: some View {
        Group {
            if let initials = orgInitials {
                Text(initials)
                    .font(.system(size: 20, weight: .semibold))
            } else {
                Image(systemName: "hexagon")
                    .font(.system(size: 24, weight: .medium))
            }
        }
        .frame(width: 60, height: 60)
        .overlay(alignment: .bottomTrailing) {
            if paidPlan == true {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tint)
                    .background(Circle().fill(.background))
                    .offset(x: 4, y: 4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .hoverEffect()
    }

    /// Up to two leading initials from the active org's name; nil before any org loads.
    private var orgInitials: String? {
        guard let name = activeOrganizationName, !name.isEmpty else { return nil }
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        let initials = String(letters).uppercased()
        return initials.isEmpty ? nil : initials
    }

    /// Hover/gaze label: the active org name and its plan, or a plain fallback.
    private var orgHelp: String {
        guard let name = activeOrganizationName else { return "Organization" }
        switch paidPlan {
        case .some(true): return "\(name) · Pro"
        case .some(false): return "\(name) · Free"
        case .none: return name
        }
    }

    private var orgAccessibilityLabel: String {
        activeOrganizationName.map { "Organization, \($0)" } ?? "Organization"
    }
}

/// One icon-only rail button: an SF Symbol in a 60pt target, the title surfaced on
/// hover/gaze via `.help()` rather than shown inline, with a hover effect for gaze feedback.
private struct RailItem: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var isEnabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RailItemLabel(systemImage: systemImage, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The shared visual for a rail item — sized for a 60pt gaze target inside the 72pt rail,
/// tinted when selected, with a hover effect so gaze lands legibly.
private struct RailItemLabel: View {
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 24, weight: .medium))
            .frame(width: 60, height: 60)
            .background(
                .tint.opacity(isSelected ? 0.22 : 0),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .hoverEffect()
    }
}
