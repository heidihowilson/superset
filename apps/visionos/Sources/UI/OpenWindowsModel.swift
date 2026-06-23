import Foundation
import Observation

/// Tracks which Workspace/Project content windows are currently open, keyed by domain
/// id. SwiftUI exposes no roster of open windows, so each window self-registers on
/// appear and deregisters on disappear. This backs the explicit "close other windows /
/// consolidate" action (PRD §9), which needs the set of ids to dismiss.
///
/// Registration is **reference-counted** per id, not a plain `Set`. On a SwiftUI
/// restore/retarget/rapid-reopen the old view's `onDisappear` can fire *after* the new
/// view's `onAppear` for the same id — with a bare set that ordering deregisters an id
/// whose window is still open, so Consolidate misses it and the count undercounts. The
/// count holds the id present until every registration for it has been balanced.
@MainActor
@Observable
final class OpenWindowsModel {
    private var workspaceCounts: [Workspace.ID: Int] = [:]
    private var projectCounts: [Project.ID: Int] = [:]

    var openWorkspaceIDs: Set<Workspace.ID> { Set(workspaceCounts.keys) }
    var openProjectIDs: Set<Project.ID> { Set(projectCounts.keys) }

    var openWindowCount: Int { workspaceCounts.count + projectCounts.count }

    func registerWorkspace(_ id: Workspace.ID) { workspaceCounts[id, default: 0] += 1 }
    func unregisterWorkspace(_ id: Workspace.ID) { Self.release(id, from: &workspaceCounts) }
    func registerProject(_ id: Project.ID) { projectCounts[id, default: 0] += 1 }
    func unregisterProject(_ id: Project.ID) { Self.release(id, from: &projectCounts) }

    /// Drop one registration for `id`, removing it only when the last is balanced. An
    /// unmatched release (no live registration) is a no-op, never a negative count.
    private static func release<ID: Hashable>(_ id: ID, from counts: inout [ID: Int]) {
        guard let count = counts[id] else { return }
        if count <= 1 { counts[id] = nil } else { counts[id] = count - 1 }
    }
}
