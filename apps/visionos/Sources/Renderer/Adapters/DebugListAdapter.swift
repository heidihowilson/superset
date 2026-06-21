import SwiftUI

/// Throwaway second adapter (M0). Renders the *same* unmodified `WorkspaceStore`
/// in a deliberately different, minimal presentation to prove the renderer seam:
/// flip the active adapter and the identical store — including live selection —
/// drives a new UI with zero domain change (PRD §17, M0).
///
/// Not a shipping interaction model; it exists only to demonstrate separation and
/// is expected to be deleted once a real second model (e.g. multi-window) lands.
struct DebugListAdapter: WorkspaceAdapter {
    let id = "debug-text"
    let displayName = "Debug Text"

    func view(for kind: PaneKind, store: WorkspaceStore) -> AnyView {
        AnyView(DebugDumpView(store: store))
    }
}
