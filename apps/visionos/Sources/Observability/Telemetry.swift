import Foundation
import os

/// App-wide analytics + crash-report sink (ADR-0007). Immutable and `Sendable`: it holds
/// only the resolved transport and the device context, so `capture` can be called from
/// any isolation — the MainActor UI and MetricKit's background diagnostic delivery — and
/// simply fans the send onto a detached task.
///
/// The transport is PostHog in the field and a console logger when no key is configured,
/// so the full path is wired without secrets. The device context is merged into every
/// event for device/model segmentation; it never carries gaze (§13).
///
/// Sends are bounded to `maxInFlight` concurrent requests: the host being asleep is the
/// normal case, and an unreachable PostHog would otherwise let every tick enqueue another
/// timing-out POST (issue #75). The admission check is synchronous, so an event arriving
/// while the window is full is dropped before a task is ever spawned rather than piling up
/// — stale analytics offline are worth less than an unbounded backlog of hung requests.
final class Telemetry: Sendable {
    private let transport: TelemetryTransport
    private let context: DeviceContext
    private let maxInFlight: Int
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)

    init(transport: TelemetryTransport, context: DeviceContext, maxInFlight: Int = 8) {
        self.transport = transport
        self.context = context
        self.maxInFlight = Swift.max(1, maxInFlight)
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
        let admitted = inFlight.withLock { count -> Bool in
            guard count < maxInFlight else { return false }
            count += 1
            return true
        }
        guard admitted else { return }
        let transport = transport
        let distinctID = context.distinctID
        let inFlight = inFlight
        Task.detached {
            await transport.send(enriched, distinctID: distinctID)
            inFlight.withLock { $0 -= 1 }
        }
    }
}
