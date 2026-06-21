import Foundation
import Observation

/// Registry of interaction-model adapters plus the active selection. Switching the
/// active adapter swaps the whole presentation with no domain or store change
/// (PRD §10) — a new model costs only "adapter + flag + config".
///
/// Built to the minimum that proves separation (M0): no speculative spatial
/// abstraction, just enough to drive one store from two registered adapters.
@MainActor
@Observable
final class AdapterRegistry {
    let adapters: [any WorkspaceAdapter]
    private(set) var activeAdapterID: String

    init(adapters: [any WorkspaceAdapter]) {
        precondition(!adapters.isEmpty, "AdapterRegistry requires at least one adapter")
        let ids = adapters.map(\.id)
        precondition(Set(ids).count == ids.count, "AdapterRegistry requires unique adapter IDs")
        self.adapters = adapters
        self.activeAdapterID = adapters[0].id
    }

    var activeAdapter: any WorkspaceAdapter {
        adapters.first { $0.id == activeAdapterID } ?? adapters[0]
    }

    func activate(_ id: String) {
        guard adapters.contains(where: { $0.id == id }) else { return }
        activeAdapterID = id
    }
}
