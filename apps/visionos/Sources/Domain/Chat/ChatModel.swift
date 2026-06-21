import Foundation

/// A model the cloud offers for a chat turn (`chat.getModels`, PRD §7.2). The model
/// picker is the one composer control that is **cloud-sourced**, so it populates even
/// when the Workspace's Host is asleep — its choice rides on `chat.sendMessage`'s
/// `metadata.model`. Hand-typed at the boundary (PRD §12): only the fields the picker
/// shows are decoded.
struct ChatModel: Identifiable, Sendable, Equatable, Codable {
    /// Provider-qualified id sent back as `metadata.model` (e.g. `anthropic/claude-opus-4-8`).
    let id: String
    /// Display name (e.g. "Opus 4.8").
    let name: String
    /// Grouping label for the menu (e.g. "Anthropic").
    let provider: String
}
