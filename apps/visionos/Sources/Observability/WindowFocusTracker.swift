import Foundation

/// Tracks one window's open foreground-dwell interval so M3 (§13) is recorded exactly once,
/// whether the window backgrounds (an inactive transition) or closes while still active (an
/// `onDisappear` with no preceding inactive transition).
///
/// `begin` opens the interval on the active transition; `flush` records any open interval to
/// the caller and clears it. Because `flush` clears the start, a second flush — or a flush
/// with nothing open — is a no-op, so the active/inactive boundary and the trailing
/// disappear can both call it without double-counting the dwell.
@MainActor
struct WindowFocusTracker {
    let kind: String
    private let clock: ContinuousClock
    private var start: ContinuousClock.Instant?

    init(kind: String, clock: ContinuousClock = ContinuousClock()) {
        self.kind = kind
        self.clock = clock
    }

    /// Open an interval at the active transition. Re-opening simply restarts from now.
    mutating func begin() {
        start = clock.now
    }

    /// Record any open interval's seconds and clear it. A no-op when no interval is open.
    mutating func flush(_ record: (_ kind: String, _ seconds: Double) -> Void) {
        guard let start else { return }
        record(kind, Self.seconds(clock.now - start))
        self.start = nil
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
