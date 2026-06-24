import Foundation
import Observation
import OSLog

/// MainActor coordinator for the product metrics that depend on app/window lifecycle:
/// M1 (time-to-first-view), M3 (per-window focus time), M4 (session length), and
/// M-Host (% sessions with a live Host) — PRD §17. It also conforms to
/// `HostCallRecording`, so the watch poll loop's outcomes both feed the M-Host flag and
/// emit the structured stream/host-call log (ADR-0007).
///
/// All timing uses a monotonic `ContinuousClock`, so it is immune to wall-clock changes.
@MainActor
@Observable
final class SessionMetrics: HostCallRecording {
    private let telemetry: Telemetry
    private let clock: ContinuousClock
    private let logger = Logger(subsystem: Logging.subsystem, category: "host-call")

    private let launchInstant: ContinuousClock.Instant
    private var firstViewRecorded = false
    private var signInObserved = false

    private var sessionStart: ContinuousClock.Instant?
    private var hadLiveHost = false

    init(telemetry: Telemetry, clock: ContinuousClock = ContinuousClock()) {
        self.telemetry = telemetry
        self.clock = clock
        launchInstant = clock.now
    }

    // MARK: - M1 — time-to-first-meaningful-view

    /// Record that a sign-in was needed this launch, so M1 is reported as a cold start
    /// (token absent → includes the sign-in flow) rather than warm.
    func noteSignInRequired() {
        guard !firstViewRecorded else { return }
        signInObserved = true
    }

    /// Emit M1 the first time the Workspace browser surface appears; later appearances
    /// are ignored.
    func markFirstMeaningfulView() {
        guard !firstViewRecorded else { return }
        firstViewRecorded = true
        let milliseconds = Self.milliseconds(clock.now - launchInstant)
        telemetry.capture(.firstMeaningfulView(milliseconds: milliseconds, warm: !signInObserved))
    }

    // MARK: - M4 / M-Host — session length + live-Host coverage

    /// Mark the start of a foreground session. Idempotent across the active/inactive
    /// churn of multiple windows — only the first activation opens the session.
    func sessionDidStart() {
        guard sessionStart == nil else { return }
        sessionStart = clock.now
        hadLiveHost = false
    }

    /// Close the session on background, emitting M4 (length) and M-Host (whether a live
    /// Host was reached). A no-op if no session is open.
    func sessionDidEnd() {
        guard let start = sessionStart else { return }
        sessionStart = nil
        let seconds = Self.seconds(clock.now - start)
        telemetry.capture(.sessionEnded(seconds: seconds, hadLiveHost: hadLiveHost))
        telemetry.capture(.hostSession(hadLiveHost: hadLiveHost))
    }

    // MARK: - M3 — per-window focus time

    /// Emit M3 for one window's foreground dwell (foreground time, never gaze, §13).
    func recordWindowFocus(kind: String, seconds: Double) {
        guard seconds > 0 else { return }
        telemetry.capture(.windowFocus(kind: kind, seconds: seconds))
    }

    // MARK: - HostCallRecording (structured stream/host-call log + M-Host flag)

    func record(_ outcome: HostCallOutcome, workspaceID: String) {
        switch outcome {
        case let .poll(latency):
            hadLiveHost = true
            logger.info(
                "host-call ok workspace=\(workspaceID, privacy: .public) latency_ms=\(Self.milliseconds(latency), privacy: .public)"
            )
        case let .hostOffline(planGated, latency):
            logger.notice(
                "host-offline workspace=\(workspaceID, privacy: .public) plan_gated=\(planGated, privacy: .public) latency_ms=\(Self.milliseconds(latency), privacy: .public)"
            )
        case let .drop(reason, latency):
            logger.error(
                "host-call drop workspace=\(workspaceID, privacy: .public) reason=\(reason, privacy: .public) latency_ms=\(Self.milliseconds(latency), privacy: .public)"
            )
        }
    }

    // MARK: - Duration helpers

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((seconds(duration) * 1000).rounded())
    }
}
