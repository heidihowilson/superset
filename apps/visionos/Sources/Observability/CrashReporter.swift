import Foundation
import MetricKit

/// MetricKit-backed crash/hang reporting (ADR-0007 — "Sentry visionOS SDK or
/// MetricKit"). MetricKit is first-party and needs no third-party SDK or network
/// dependency in the build: the system delivers `MXCrashDiagnostic`/`MXHangDiagnostic`
/// payloads on the launch after a crash/hang, which we forward to the telemetry
/// transport so field crashes are visible alongside the product metrics.
///
/// Diagnostics arrive on a background queue; `Telemetry` is `Sendable` and the only
/// stored state, so the subscriber is safe to use off the main actor.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let telemetry: Telemetry

    init(telemetry: Telemetry) {
        self.telemetry = telemetry
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    /// Required by the subscriber protocol; the app emits its own product metrics, so the
    /// system metric payloads are not consumed here.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                telemetry.capture(Self.crashEvent(crash))
            }
            for hang in payload.hangDiagnostics ?? [] {
                telemetry.capture(Self.hangEvent(hang))
            }
        }
    }

    private static func crashEvent(_ crash: MXCrashDiagnostic) -> TelemetryEvent {
        TelemetryEvent(name: "crash", properties: [
            "exception_type": .int(crash.exceptionType?.intValue ?? -1),
            "exception_code": .int(crash.exceptionCode?.intValue ?? -1),
            "signal": .int(crash.signal?.intValue ?? -1),
            "termination_reason": .string(crash.terminationReason ?? "unknown"),
            "app_build": .string(crash.metaData.applicationBuildVersion),
            "os_version": .string(crash.metaData.osVersion),
        ])
    }

    private static func hangEvent(_ hang: MXHangDiagnostic) -> TelemetryEvent {
        TelemetryEvent(name: "hang", properties: [
            "hang_duration_ms": .int(Int(hang.hangDuration.converted(to: .milliseconds).value.rounded())),
            "app_build": .string(hang.metaData.applicationBuildVersion),
            "os_version": .string(hang.metaData.osVersion),
        ])
    }
}
