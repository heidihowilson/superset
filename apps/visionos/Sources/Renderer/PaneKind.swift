import Foundation

/// The content kinds the renderer registry can present. SwiftUI views in V1,
/// RealityKit in V2 — the boundary swaps, the kinds stay stable (PRD §6.2).
///
/// Deferred/cut kinds stay registered as placeholders so synced layouts remain
/// valid (PRD §8); only `workspaceList` has a live renderer at M0.
enum PaneKind: String, CaseIterable, Sendable {
    case workspaceList
    case chat
    case diff
    case file
    case comment
    case terminal
    case browser
}
