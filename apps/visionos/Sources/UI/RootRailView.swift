import SwiftUI

/// The content surfaces the icon rail switches between in the root window. Each maps to a
/// rail item; the selected one fills the content pane. `workspaces` is the default (and
/// becomes the collapsible project tree in a later slice); `automations` and `tasks` are
/// placeholder panes until wired.
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
/// effect. Selecting a destination swaps the content pane in `RootView`; ＋ opens the
/// create sheet, and ⬡ Org opens a menu (it carries Settings now; switch-org and Sign out
/// land in a later slice).
struct RootRailView: View {
    @Binding var selection: RailDestination
    let canCreateWorkspace: Bool
    var onNewWorkspace: () -> Void
    var onOpenSettings: () -> Void

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

    /// ⬡ Org — the IA places Settings in this menu, so slice 1 carries it; switch-org and
    /// Sign out are added in a later slice.
    private var orgItem: some View {
        Menu {
            Button("Settings", systemImage: "gearshape", action: onOpenSettings)
        } label: {
            RailItemLabel(systemImage: "hexagon", isSelected: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Organization")
        .accessibilityLabel("Organization")
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
                isSelected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .hoverEffect()
    }
}
