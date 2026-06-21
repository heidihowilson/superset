import Foundation

/// A single analytics event: a stable `name` plus primitive `properties`. The product
/// metrics (M1/M3/M4/M-Host, PRD §17) and the crash/hang reports are all expressed as
/// events so one transport (PostHog, ADR-0007) carries them.
///
/// The metric constructors expose only window-kind and durations — never look direction
/// — so the §13 privacy invariant ("never log gaze") holds by construction.
struct TelemetryEvent: Sendable, Equatable {
    let name: String
    var properties: [String: TelemetryValue]

    init(name: String, properties: [String: TelemetryValue] = [:]) {
        self.name = name
        self.properties = properties
    }
}

extension TelemetryEvent {
    /// M1 — time-to-first-meaningful-view (launch → first Workspace surface, PRD §17).
    static func firstMeaningfulView(milliseconds: Int, warm: Bool) -> TelemetryEvent {
        TelemetryEvent(name: "m1_time_to_first_view", properties: [
            "duration_ms": .int(milliseconds),
            "launch_kind": .string(warm ? "warm" : "cold"),
        ])
    }

    /// M3 — per-window focus/foreground time. This is foreground dwell, not gaze:
    /// visionOS exposes no raw gaze and we never log it (PRD §17, §13).
    static func windowFocus(kind: String, seconds: Double) -> TelemetryEvent {
        TelemetryEvent(name: "m3_window_focus", properties: [
            "window_kind": .string(kind),
            "focus_seconds": .double(seconds),
        ])
    }

    /// M4 — comfortable session length, carrying the same session's M-Host flag so the
    /// two read together when segmenting.
    static func sessionEnded(seconds: Double, hadLiveHost: Bool) -> TelemetryEvent {
        TelemetryEvent(name: "m4_session_length", properties: [
            "session_seconds": .double(seconds),
            "had_live_host": .bool(hadLiveHost),
        ])
    }

    /// M-Host — whether this session ever reached a live Host tunnel (PRD §17, validates
    /// the host-awake assumption).
    static func hostSession(hadLiveHost: Bool) -> TelemetryEvent {
        TelemetryEvent(name: "m_host_session", properties: [
            "had_live_host": .bool(hadLiveHost),
        ])
    }
}
