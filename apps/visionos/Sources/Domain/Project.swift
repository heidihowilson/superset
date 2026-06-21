import Foundation

/// A GitHub-linked repository under an Organization that groups Workspaces
/// (CONTEXT.md). The browser groups the Workspace list by Project; an empty Project
/// still renders as a group so a user knows it exists before opening a Workspace.
struct Project: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
}
