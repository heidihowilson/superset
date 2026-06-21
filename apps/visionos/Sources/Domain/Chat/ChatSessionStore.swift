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
    /// Drives only the empty-state UI. A populated transcript is always shown — a poll
    /// that is loading or has failed never blanks it.
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var transcript: ChatTranscript = .empty
    private(set) var loadState: LoadState = .idle

    /// Records each poll's outcome for the ADR-0007 stream/host-call telemetry and the
    /// M-Host flag. Optional and weak so the Domain layer stays transport-agnostic and
    /// never retains the UI-owned sink.
    weak var hostCallRecorder: (any HostCallRecording)?

    private var provider: ChatTranscriptProviding?
    private let pollInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    /// The Workspace the bound provider serves, so re-binding the same Workspace is a
    /// no-op (keeps the transcript) while switching Workspaces resets it.
    private var boundWorkspaceID: String?

    init(pollInterval: Duration = .seconds(2)) {
        self.pollInterval = pollInterval
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
    /// the empty case.
    func refresh() async {
        guard let provider else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if transcript.isEmpty { loadState = .loading }
        let start = ContinuousClock().now
        do {
            let fetched = try await provider.fetchTranscript()
            guard generation == refreshGeneration else { return }
            transcript = fetched
            loadState = .loaded
            hostCallRecorder?.record(.poll(latency: ContinuousClock().now - start), workspaceID: boundWorkspaceID ?? "")
        } catch is CancellationError {
            // Polling was cancelled (hidden/backgrounded) — keep the last good transcript
            // and don't log it as a host-call outcome; it's an intentional pause.
        } catch {
            guard generation == refreshGeneration else { return }
            loadState = transcript.isEmpty ? .failed(Self.message(for: error)) : .loaded
            recordFailure(error)
        }
    }

    /// Map a poll failure onto a host-call outcome: a 403 is the plan-gated host-offline
    /// state (PRD §6.3), everything else is a drop.
    private func recordFailure(_ error: Error) {
        let outcome: HostCallOutcome = switch error {
        case let AuthError.badServerResponse(status) where status == 403:
            .hostOffline(planGated: true)
        default:
            .drop(reason: String(describing: error))
        }
        hostCallRecorder?.record(outcome, workspaceID: boundWorkspaceID ?? "")
    }

    /// Begin polling while the window is visible. Idempotent.
    func startPolling() {
        guard provider != nil, pollingTask == nil else { return }
        let interval = pollInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                if Task.isCancelled { break }
                try? await Task.sleep(for: interval)
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
        switch error {
        case AuthError.notAuthenticated:
            return "Not signed in."
        case AuthError.noActiveOrganization:
            return "No organization available."
        case let AuthError.badServerResponse(status) where status == 403:
            return "Watch needs a reachable Host on a paid plan."
        case let AuthError.badServerResponse(status):
            return "Host returned HTTP \(status)."
        default:
            return "Couldn't reach the Host. Retrying…"
        }
    }
}
