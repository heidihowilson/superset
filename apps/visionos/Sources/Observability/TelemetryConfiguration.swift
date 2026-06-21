import Foundation

/// Build-time telemetry endpoints (ADR-0007). The PostHog project key and host are read
/// from the app's Info.plist (`POSTHOG_API_KEY` / `POSTHOG_HOST`), so a build without
/// the key configured runs the console transport instead of the network — telemetry is
/// wired and exercised without requiring a secret in CI or local dev.
struct TelemetryConfiguration: Sendable {
    let postHogAPIKey: String?
    let postHogHost: URL

    static let defaultHost = URL(string: "https://us.i.posthog.com")!

    static func resolved(bundle: Bundle = .main) -> TelemetryConfiguration {
        let info = bundle.infoDictionary
        let key = (info?["POSTHOG_API_KEY"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let host = (info?["POSTHOG_HOST"] as? String)
            .flatMap(URL.init(string:)) ?? defaultHost
        return TelemetryConfiguration(postHogAPIKey: key, postHogHost: host)
    }
}
