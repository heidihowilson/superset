import SwiftUI
import Observation

/// Device-local user preferences — the slice of Settings that lives on this Vision Pro
/// rather than the cloud session (PRD §7.2): app appearance, the co-equal-input
/// dictation toggle (§9), in-app notification opt-in, and a preferred default chat
/// model. Backed by `UserDefaults` like `UserDefaultsPendingStateStore`
/// (none of these are secrets); the cloud-scoped
/// setting — the active organization — flows through the auth session instead.
@MainActor
@Observable
final class AppSettingsStore {
    /// App color-scheme preference. `.system` defers to the device-wide setting.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Whether voice dictation is offered as a composer input. Device-local because the
    /// §9 on-device-recognition fallback is a per-device privacy choice.
    var dictationEnabled: Bool {
        didSet { defaults.set(dictationEnabled, forKey: Keys.dictationEnabled) }
    }

    /// In-app notification opt-in (PRD §7.2 — out-of-headset alerting stays out of V1).
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// Preferred default chat-model id; `nil` lets the cloud/Host pick. Consumed by the
    /// composer's initial model selection (`ComposerStore.loadPickers`).
    var preferredModelID: String? {
        didSet {
            if let preferredModelID {
                defaults.set(preferredModelID, forKey: Keys.preferredModelID)
            } else {
                defaults.removeObject(forKey: Keys.preferredModelID)
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Keys.appearance)
            .flatMap(Appearance.init(rawValue:)) ?? .system
        // Dictation stays off until the §9 word-error-rate bar is met; notifications
        // default on. `object(forKey:)` distinguishes an unset key from a stored `false`.
        dictationEnabled = defaults.object(forKey: Keys.dictationEnabled) as? Bool ?? false
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        preferredModelID = defaults.string(forKey: Keys.preferredModelID)
    }

    private enum Keys {
        static let appearance = "settings.appearance.v1"
        static let dictationEnabled = "settings.dictation.enabled.v1"
        static let notificationsEnabled = "settings.notifications.enabled.v1"
        static let preferredModelID = "settings.model.preferred.v1"
    }
}
