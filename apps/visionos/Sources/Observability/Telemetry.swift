import Foundation

/// App-wide analytics + crash-report sink (ADR-0007). Immutable and `Sendable`: it holds
/// only the resolved transport and the device context, so `capture` can be called from
/// any isolation — the MainActor UI and MetricKit's background diagnostic delivery — and
/// simply fans the send onto a detached task.
///
/// The transport is PostHog in the field and a console logger when no key is configured,
/// so the full path is wired without secrets. The device context is merged into every
/// event for device/model segmentation; it never carries gaze (§13).
final class Telemetry: Sendable {
    private let transport: TelemetryTransport
    private let context: DeviceContext

    init(transport: TelemetryTransport, context: DeviceContext) {
        self.transport = transport
        self.context = context
    }

    /// Build the live sink: PostHog when a project key is configured, else the console
    /// transport so local/CI builds still exercise the path.
    static func live(
        configuration: TelemetryConfiguration = .resolved(),
        context: DeviceContext = .resolve()
    ) -> Telemetry {
        let transport: TelemetryTransport = configuration.postHogAPIKey.map {
            PostHogTransport(apiKey: $0, host: configuration.postHogHost)
        } ?? ConsoleTelemetryTransport()
        return Telemetry(transport: transport, context: context)
    }

    /// Enrich with the device context and send. Per-event properties win over context
    /// defaults so an explicit value is never overwritten.
    func capture(_ event: TelemetryEvent) {
        var enriched = event
        for (key, value) in context.properties where enriched.properties[key] == nil {
            enriched.properties[key] = value
        }
        let transport = transport
        let distinctID = context.distinctID
        Task.detached { await transport.send(enriched, distinctID: distinctID) }
    }
}
