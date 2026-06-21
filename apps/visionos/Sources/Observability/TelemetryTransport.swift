import Foundation

/// Where a `TelemetryEvent` goes once captured. `Sendable` so `Telemetry.capture` can
/// fan a send onto a detached task from any isolation (the MainActor UI, MetricKit's
/// background diagnostic delivery).
protocol TelemetryTransport: Sendable {
    func send(_ event: TelemetryEvent, distinctID: String) async
}
