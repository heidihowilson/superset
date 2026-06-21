import Foundation
import Observation

/// A registered, feature-flagged interaction model (PRD §10). The model only differs
/// in its `windowing` policy — switching re-renders the *same* store at runtime, no
/// rebuild and no domain change (the experiment's whole point).
struct InteractionModel: Identifiable, Hashable {
    /// How opening a Workspace/Project behaves.
    enum Windowing: Hashable {
        /// Default: at most one content window at a time — opening another consolidates
        /// the rest, so the switcher (not a wall of windows) is the navigation surface.
        case singleWindowPlusSwitcher
        /// Opt-in: every opened domain id gets its own window (open-or-focus), windows
        /// coexist. Proliferation is mitigated by the explicit consolidate action (§9).
        case multiWindow
    }

    let id: String
    let displayName: String
    let windowing: Windowing
}

extension InteractionModel {
    static let singleWindowPlusSwitcher = InteractionModel(
        id: "single-window-plus-switcher",
        displayName: "Single Window",
        windowing: .singleWindowPlusSwitcher
    )

    static let multiWindow = InteractionModel(
        id: "multi-window",
        displayName: "Multi-Window",
        windowing: .multiWindow
    )

    /// Registered models; the first is the default (PRD §10: single-window-plus-switcher
    /// ships on, multi-window is the opt-in contender).
    static let builtIn: [InteractionModel] = [singleWindowPlusSwitcher, multiWindow]
}

/// The Interaction Model Registry (PRD §10): the set of registered models plus the
/// flagged active one, persisted in `UserDefaults` so the chosen experiment survives
/// relaunch. Shared across windows; flipping the model changes window behavior live.
@MainActor
@Observable
final class InteractionModelRegistry {
    let models: [InteractionModel]
    private(set) var activeModelID: String

    private let defaultsKey = "interaction.model.v1"

    init(models: [InteractionModel] = InteractionModel.builtIn) {
        precondition(!models.isEmpty, "InteractionModelRegistry needs at least one model")
        self.models = models
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        activeModelID = models.first { $0.id == stored }?.id ?? models[0].id
    }

    var activeModel: InteractionModel {
        models.first { $0.id == activeModelID } ?? models[0]
    }

    /// Switch the active model (the experiment flag). Unknown ids are ignored so a stale
    /// persisted value can never select a model that is no longer registered.
    func activate(_ id: String) {
        guard models.contains(where: { $0.id == id }) else { return }
        activeModelID = id
        UserDefaults.standard.set(id, forKey: defaultsKey)
    }
}
