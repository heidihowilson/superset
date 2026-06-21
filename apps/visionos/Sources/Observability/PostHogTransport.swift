import Foundation
import OSLog

/// PostHog HTTP capture transport — the metrics pipeline web/mobile/desktop already use
/// (ADR-0007). Posts one event to `${host}/capture`; a failed send is logged and
/// dropped, never surfaced, because telemetry must never break the watch loop. The
/// `api_key` is PostHog's public project key (not a secret), so it lives in the build
/// config rather than the Keychain.
struct PostHogTransport: TelemetryTransport {
    let apiKey: String
    let host: URL
    var session: URLSession = .shared

    private static let logger = Logger(subsystem: Logging.subsystem, category: "telemetry")

    func send(_ event: TelemetryEvent, distinctID: String) async {
        var request = URLRequest(url: host.appendingPathComponent("capture"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var properties: [String: Any] = [:]
        for (key, value) in event.properties { properties[key] = value.jsonObject }
        let payload: [String: Any] = [
            "api_key": apiKey,
            "event": event.name,
            "distinct_id": distinctID,
            "properties": properties,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = body

        do {
            _ = try await session.data(for: request)
        } catch {
            Self.logger.debug("telemetry send failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Fallback transport for builds with no PostHog key (local/dev/CI): writes each event
/// to the unified log instead of the network, so the full telemetry path is exercised
/// and observable without secrets.
struct ConsoleTelemetryTransport: TelemetryTransport {
    private static let logger = Logger(subsystem: Logging.subsystem, category: "telemetry")

    func send(_ event: TelemetryEvent, distinctID: String) async {
        Self.logger.info(
            "event=\(event.name, privacy: .public) distinct_id=\(distinctID, privacy: .public) properties=\(String(describing: event.properties), privacy: .public)"
        )
    }
}

/// Shared unified-logging identifiers for the observability subsystem (ADR-0007).
enum Logging {
    static let subsystem = "sh.superset.visionos"
}
