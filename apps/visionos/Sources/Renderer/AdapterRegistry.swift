import Foundation
import Observation

/// Registry of interaction-model adapters plus the active selection. The active
/// adapter renders the whole presentation with no domain or store change (PRD §10)
/// — a new model costs only "adapter + flag + config".
///
/// Built to the minimum that proves separation (M0): no speculative spatial
/// abstraction, just enough to drive one store through a registered adapter.
@MainActor
@Observable
final class AdapterRegistry {
    let adapters: [any WorkspaceAdapter]
    let activeAdapterID: String

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
}
