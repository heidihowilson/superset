import Foundation

/// The content kinds the renderer registry can present. SwiftUI views in V1,
/// RealityKit in V2 — the boundary swaps, the kinds stay stable (PRD §6.2).
///
/// Only `workspaceList` has a live renderer at M0; further kinds are added here
/// as their renderers land.
enum PaneKind: String, Sendable {
    case workspaceList
}
