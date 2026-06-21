import SwiftUI

/// Identifiers for the Workspace window scene, shared by the App (which declares the
/// `WindowGroup`) and the switcher/list (which open it by Workspace id).
enum WorkspaceScene {
    static let windowID = "workspace"
}

/// The leading-ornament Workspace switcher (PRD §9: chrome lives in ornaments, not
/// inline toolbars). A compact, glanceable column of the cloud-listed Workspaces with
/// status dots; tapping one selects it and opens/focuses its Workspace window. Because
/// the window is keyed by Workspace id, re-tapping focuses the existing window.
struct WorkspaceSwitcherView: View {
    @Bindable var store: WorkspaceStore
    @Environment(InteractionModelRegistry.self) private var models
    @Environment(OpenWindowsModel.self) private var openWindows
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
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
            .padding()
        }
        .frame(width: 240, height: 420)
        .glassBackgroundEffect()
    }
}
