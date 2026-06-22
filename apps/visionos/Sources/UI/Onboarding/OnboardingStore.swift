import Foundation
import Observation

/// First-run onboarding state (PRD §7.2 / §16.3, FR-ONB). The 5-beat tour is
/// lightweight, **skippable**, and **settings-replayable**, so this store separates two
/// concerns: a durable `hasCompletedFirstRun` flag (persisted in `UserDefaults` like
/// `AppSettingsStore` — not a secret) that gates the
/// automatic first-run presentation, and a transient `isPresented` flag that drives the
/// sheet. Replaying from Settings flips `isPresented` without disturbing the durable flag,
/// so a deliberate re-watch never re-arms the automatic first-run trigger.
@MainActor
@Observable
final class OnboardingStore {
    /// Drives the onboarding sheet. Seeded from the durable flag so a genuinely new
    /// install presents the tour the first time the user reaches a signed-in surface;
    /// the sheet itself is bound in the signed-in branch, so it never shows over sign-in.
    var isPresented: Bool

    /// Whether the user has finished or skipped the first-run tour at least once. Durable
    /// so the tour auto-presents exactly once per install, not on every relaunch.
    private(set) var hasCompletedFirstRun: Bool {
        didSet { defaults.set(hasCompletedFirstRun, forKey: Keys.completed) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let completed = defaults.bool(forKey: Keys.completed)
        hasCompletedFirstRun = completed
        isPresented = !completed
    }

    /// Finish or skip the tour: dismiss the sheet and record the first run as done so it
    /// won't auto-present again. Idempotent — a replay that completes just re-sets the
    /// already-true flag. Any sheet dismissal (Done, Skip, or an interactive swipe-down)
    /// routes here, so first-run is marked complete however the user leaves.
    func complete() {
        hasCompletedFirstRun = true
        isPresented = false
    }

    /// Re-present the tour on demand (the Settings "replay" affordance). Leaves the durable
    /// flag untouched so this deliberate re-watch doesn't re-arm the automatic first-run
    /// presentation on the next launch.
    func replay() {
        isPresented = true
    }

    private enum Keys {
        static let completed = "onboarding.firstRun.completed.v1"
    }
}
