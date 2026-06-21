import Foundation
import Observation

/// Presentation-agnostic source of truth for Workspace domain state. Renderer
/// adapters observe it and emit intents; the UI never owns domain state (PRD §6.2).
///
/// No SwiftUI, no Electron, no Electric. In later milestones this is fed by
/// bearer-authed cloud tRPC (the polled Workspace list) and host-service-over-relay
/// reads; M0 seeds it with sample data to prove the renderer seam.
@MainActor
@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace]
    private(set) var selectedWorkspaceID: Workspace.ID?

    init(workspaces: [Workspace] = []) {
        self.workspaces = workspaces
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    // MARK: Intents — UI emits these; it never mutates domain state directly.

    func select(_ id: Workspace.ID?) {
        selectedWorkspaceID = id
    }
}

extension WorkspaceStore {
    /// M0 seed data (no network yet). Replaced by the polled cloud tRPC list in a
    /// later issue — the renderer seam is what M0 proves, not the data source.
    static func sample() -> WorkspaceStore {
        WorkspaceStore(workspaces: [
            Workspace(id: "ws-auth", name: "auth-handoff", projectName: "superset", status: .running),
            Workspace(id: "ws-relay", name: "relay-tunnel", projectName: "superset", status: .idle),
            Workspace(id: "ws-vision", name: "vision-pro-app", projectName: "superset", status: .hostAsleep),
        ])
    }
}
