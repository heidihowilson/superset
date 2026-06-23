import SwiftUI

/// A presentation over the shared domain store — an "interaction model" in the
/// experimentation framework (PRD §10). An adapter observes the store and renders
/// the registered view for a `PaneKind`; it emits intents but never owns domain
/// state (PRD §6.2).
///
/// Swapping the active adapter re-renders the *same unmodified* store at runtime
/// with zero domain change — this is the seam M0 proves (PRD §17, M0).
@MainActor
protocol WorkspaceAdapter {
    var id: String { get }

    /// The SwiftUI view this adapter registers for `kind`, bound to `store`.
    func view(for kind: PaneKind, store: WorkspaceStore) -> AnyView
}
