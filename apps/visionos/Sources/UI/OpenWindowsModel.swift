import Foundation
import Observation

/// Tracks which Workspace/Project content windows are currently open, keyed by domain
/// id. SwiftUI exposes no roster of open windows, so each window self-registers on
/// appear and deregisters on disappear. This backs two things: the "close other windows
/// / consolidate" action (PRD §9, which needs the set of ids to dismiss) and the
/// single-window-plus-switcher policy (which consolidates the rest on open).
@MainActor
@Observable
final class OpenWindowsModel {
    private(set) var openWorkspaceIDs: Set<Workspace.ID> = []
    private(set) var openProjectIDs: Set<Project.ID> = []

    var openWindowCount: Int { openWorkspaceIDs.count + openProjectIDs.count }

    func registerWorkspace(_ id: Workspace.ID) { openWorkspaceIDs.insert(id) }
    func unregisterWorkspace(_ id: Workspace.ID) { openWorkspaceIDs.remove(id) }
    func registerProject(_ id: Project.ID) { openProjectIDs.insert(id) }
    func unregisterProject(_ id: Project.ID) { openProjectIDs.remove(id) }
}
