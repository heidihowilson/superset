import Foundation
import Observation

/// Presentation-agnostic source of truth for the Workspace browser — the one
/// Host-independent surface (PRD §7.2). Renderer adapters observe it and emit
/// intents; the UI never owns domain state (PRD §6.2).
///
/// No SwiftUI, no Electron, no Electric. The list is fed by a bearer-authed cloud
/// `WorkspaceListProviding` (the polled `v2Workspace.list` + `v2Project.list`),
/// polled while visible and paused when hidden (ADR-0004). The last result is cached
/// for instant paint: on init the store paints the cached snapshot, then refreshes.
@MainActor
@Observable
final class WorkspaceStore {
    /// Drives only the empty-state UI. Cached/loaded rows are always shown — a poll
    /// that is in flight or has failed never blanks an existing list.
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var projects: [Project]
    private(set) var workspaces: [Workspace]
    private(set) var selectedWorkspaceID: Workspace.ID?
    private(set) var loadState: LoadState = .idle

    private let provider: WorkspaceListProviding?
    private let cache: WorkspaceListCaching?
    private let pollInterval: Duration
    private var pollingTask: Task<Void, Never>?

    init(
        provider: WorkspaceListProviding? = nil,
        cache: WorkspaceListCaching? = nil,
        pollInterval: Duration = .seconds(7)
    ) {
        self.provider = provider
        self.cache = cache
        self.pollInterval = pollInterval
        let cached = cache?.load() ?? .empty
        self.projects = cached.projects
        self.workspaces = cached.workspaces
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// Workspaces grouped by Project for the browser, in Project order. Empty Projects
    /// render as empty groups; a Workspace whose Project is missing from the list (or
    /// has no `projectID`) is bucketed under its embedded `projectName`, else "Other",
    /// so nothing is silently dropped.
    var groups: [WorkspaceGroup] {
        var order: [String] = []
        var names: [String: String] = [:]
        for project in projects where names[project.id] == nil {
            order.append(project.id)
            names[project.id] = project.name
        }

        var buckets: [String: [Workspace]] = [:]
        for workspace in workspaces {
            let key = workspace.projectID ?? Self.ungroupedKey
            if names[key] == nil {
                order.append(key)
                names[key] = key == Self.ungroupedKey || workspace.projectName.isEmpty
                    ? "Other"
                    : workspace.projectName
            }
            buckets[key, default: []].append(workspace)
        }

        return order.map { key in
            WorkspaceGroup(
                id: key,
                name: names[key] ?? "Other",
                workspaces: (buckets[key] ?? []).sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
    }

    // MARK: Intents — UI emits these; it never mutates domain state directly.

    func select(_ id: Workspace.ID?) {
        selectedWorkspaceID = id
    }

    /// Pull one fresh snapshot. Cache-first: a populated list stays on screen while the
    /// poll runs and even if it fails; `loadState` reflects errors for the empty case.
    func refresh() async {
        guard let provider else { return }
        if workspaces.isEmpty { loadState = .loading }
        do {
            let snapshot = try await provider.fetchSnapshot()
            apply(snapshot)
            cache?.save(snapshot)
            loadState = .loaded
        } catch is CancellationError {
            // Polling was cancelled (hidden/backgrounded) — keep the last good data.
        } catch {
            loadState = workspaces.isEmpty ? .failed(Self.message(for: error)) : .loaded
        }
    }

    /// Begin polling while the browser is visible. Idempotent — a second call while a
    /// loop is running is a no-op.
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

    /// Pause polling when the browser is hidden or the scene is backgrounded.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func apply(_ snapshot: WorkspaceListSnapshot) {
        projects = snapshot.projects
        workspaces = snapshot.workspaces
        if let selectedWorkspaceID, !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            self.selectedWorkspaceID = nil
        }
    }

    private static let ungroupedKey = "__ungrouped"

    private static func message(for error: Error) -> String {
        switch error {
        case AuthError.notAuthenticated:
            return "Not signed in."
        case AuthError.noActiveOrganization:
            return "No organization available."
        case let AuthError.badServerResponse(status):
            return "Server returned HTTP \(status)."
        default:
            return "Couldn't load workspaces. Retrying…"
        }
    }
}

/// A Project and the Workspaces under it, as rendered in the grouped browser.
struct WorkspaceGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let workspaces: [Workspace]
}

extension WorkspaceStore {
    /// In-memory sample for SwiftUI previews and the renderer-seam demo — no network.
    /// A `WorkspaceListCaching` that returns a fixed snapshot seeds the store on init.
    static func sample() -> WorkspaceStore {
        WorkspaceStore(cache: SampleCache())
    }

    private struct SampleCache: WorkspaceListCaching {
        func load() -> WorkspaceListSnapshot? {
            WorkspaceListSnapshot(
                projects: [Project(id: "p-superset", name: "superset")],
                workspaces: [
                    Workspace(id: "ws-auth", name: "auth-handoff", projectID: "p-superset", projectName: "superset", status: .hostOnline),
                    Workspace(id: "ws-relay", name: "relay-tunnel", projectID: "p-superset", projectName: "superset", status: .planGated),
                    Workspace(id: "ws-vision", name: "vision-pro-app", projectID: "p-superset", projectName: "superset", status: .hostAsleep),
                ]
            )
        }

        func save(_ snapshot: WorkspaceListSnapshot) {}
    }
}
