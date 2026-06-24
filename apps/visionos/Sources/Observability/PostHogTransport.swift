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

    /// Injection seam for failed sends — a thrown transport error or a non-2xx `/capture`
    /// response. Defaults to the unified-log debug sink; tests substitute a recorder to
    /// observe that a drop happened. Telemetry stays best-effort, so failures are only
    /// logged here, never thrown.
    var logFailure: @Sendable (String) -> Void = { message in
        PostHogTransport.logger.debug("\(message, privacy: .public)")
    }

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
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                logFailure("telemetry send rejected: HTTP \(http.statusCode)")
            }
        } catch {
            logFailure("telemetry send failed: \(error.localizedDescription)")
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
