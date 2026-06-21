import Foundation

/// An isolated git worktree on a remote Host where a coding agent runs — the
/// primary unit a user opens, watches, and organizes in space (CONTEXT.md).
struct Workspace: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var projectName: String
    var status: WorkspaceStatus
}
