import Foundation

/// Capped exponential backoff for the visible poll loops (`WorkspaceStore`,
/// `ChatSessionStore`). The host being asleep/offline is the **normal** state for the
/// host-awake app, so a failing poll must not keep hammering the network at the healthy
/// interval: each consecutive failure doubles the wait, capped at `maxInterval`. A single
/// success resets to `base`, so recovery is picked up at the fast interval with no lag.
struct PollBackoff {
    let base: Duration
    let maxInterval: Duration
    private(set) var consecutiveFailures = 0

    init(base: Duration, maxInterval: Duration) {
        self.base = base
        self.maxInterval = Swift.max(base, maxInterval)
    }

    /// The wait before the next poll given the failures recorded so far: `base` while
    /// healthy, then `base · 2ⁿ` (n = failures − 1) clamped to `maxInterval`. Computed by
    /// doubling with an early cap so the interval never grows large enough to overflow.
    var currentInterval: Duration {
        guard consecutiveFailures > 0 else { return base }
        var interval = base
        for _ in 1 ..< consecutiveFailures {
            if interval >= maxInterval { return maxInterval }
            interval *= 2
        }
        return Swift.min(interval, maxInterval)
    }

    /// Fold a poll outcome into the backoff: a success resets to `base`, a failure grows
    /// the interval toward `maxInterval`.
    mutating func record(success: Bool) {
        consecutiveFailures = success ? 0 : consecutiveFailures + 1
    }
}
