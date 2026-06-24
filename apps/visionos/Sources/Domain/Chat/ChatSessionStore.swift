import Foundation
import Observation

/// Presentation-agnostic source of truth for one Workspace's watch transcript
/// (PRD §6.2/§7.2). Polls `chat.getSnapshot` over the relay (host-service, ADR-0006)
/// while the window is visible and pauses when it backgrounds (ADR-0004). Renderer
/// views observe it; they never own domain state.
///
/// Cache-first, the M0c gate's core: the last good transcript stays on screen while a
/// poll is in flight, when a poll fails, and across a backgrounding cycle — it is
/// never blanked by an in-flight or failed refresh. Mirrors `WorkspaceStore`'s
/// generation-guarded apply so overlapping/aged polls can't clobber newer state.
@MainActor
@Observable
final class ChatSessionStore {
    private(set) var transcript: ChatTranscript = .empty
    private(set) var loadState: LoadState = .idle

    /// Records each poll's outcome for the ADR-0007 stream/host-call telemetry and the
    /// M-Host flag. Optional and weak so the Domain layer stays transport-agnostic and
    /// never retains the UI-owned sink.
    weak var hostCallRecorder: (any HostCallRecording)?

    private var provider: ChatTranscriptProviding?
    private let pollInterval: Duration
    /// Ceiling the poll backoff climbs to while the host stays unreachable (the common case
    /// for a watch session — the host sleeps). Healthy polls stay at `pollInterval`.
    private let maxPollInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    /// The Workspace the bound provider serves, so re-binding the same Workspace is a
    /// no-op (keeps the transcript) while switching Workspaces resets it.
    private var boundWorkspaceID: String?

    init(pollInterval: Duration = .seconds(2), maxPollInterval: Duration = .seconds(30)) {
        self.pollInterval = pollInterval
        self.maxPollInterval = maxPollInterval
    }

    /// Bind the provider for `workspaceID`. Re-binding the same Workspace keeps the
    /// shown transcript (cache-first across view churn); binding a different Workspace
    /// stops polling and clears, so one window never paints another's session.
    func bind(provider: ChatTranscriptProviding, workspaceID: String) {
        if boundWorkspaceID == workspaceID { return }
        stopPolling()
        refreshGeneration &+= 1
        self.provider = provider
        boundWorkspaceID = workspaceID
        transcript = .empty
        loadState = .idle
    }

    /// Pull one fresh transcript. Cache-first: a populated transcript stays on screen
    /// while the poll runs and even if it fails; `loadState` reflects errors only for
    /// the empty case. Returns whether the poll reached the host, so the loop can back off
    /// on a run of failures and recover at the fast interval on the next success. A
    /// cancelled or superseded poll is not a failure (the loop is pausing or a newer poll
    /// owns the state).
    @discardableResult
    func refresh() async -> Bool {
        guard let provider else { return true }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if transcript.isEmpty { loadState = .loading }
        let start = ContinuousClock().now
        do {
            let fetched = try await provider.fetchTranscript()
            guard generation == refreshGeneration else { return true }
            transcript = fetched
            loadState = .loaded
            hostCallRecorder?.record(.poll(latency: ContinuousClock().now - start), workspaceID: boundWorkspaceID ?? "")
            return true
        } catch is CancellationError {
            // Polling was cancelled (hidden/backgrounded) — keep the last good transcript
            // and don't log it as a host-call outcome; it's an intentional pause.
            return true
        } catch {
            guard generation == refreshGeneration else { return true }
            loadState = transcript.isEmpty ? .failed(Self.message(for: error)) : .loaded
            recordFailure(error, latency: ContinuousClock().now - start)
            return false
        }
    }

    /// Map a poll failure onto a host-call outcome: a 403 is the plan-gated host-offline
    /// state (PRD §6.3), everything else is a drop. `latency` is the elapsed poll time,
    /// recorded alongside the failure so slow/failed polls aren't dropped from the
    /// host-call latency telemetry.
    private func recordFailure(_ error: Error, latency: Duration) {
        let outcome: HostCallOutcome = switch error {
        case let AuthError.badServerResponse(status) where status == 403:
            .hostOffline(planGated: true, latency: latency)
        default:
            .drop(reason: String(describing: error), latency: latency)
        }
        hostCallRecorder?.record(outcome, workspaceID: boundWorkspaceID ?? "")
    }

    /// Begin polling while the window is visible. Idempotent.
    func startPolling() {
        guard provider != nil, pollingTask == nil else { return }
        var backoff = PollBackoff(base: pollInterval, maxInterval: maxPollInterval)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let succeeded = await self?.refresh() ?? false
                if Task.isCancelled { break }
                backoff.record(success: succeeded)
                try? await Task.sleep(for: backoff.currentInterval)
            }
        }
    }

    /// Pause polling when the window is hidden or the scene backgrounds. The transcript
    /// is retained so foregrounding re-polls onto existing data without blanking.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private static func message(for error: Error) -> String {
        AuthError.userFacingMessage(
            for: error,
            hostGated403: "Watch needs a reachable Host on a paid plan.",
            serverStatus: { "Host returned HTTP \($0)." },
            default: "Couldn't reach the Host. Retrying…"
        )
    }
}
