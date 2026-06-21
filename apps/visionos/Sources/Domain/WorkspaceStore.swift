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
    /// The org's Hosts, the targets a create can be dialed at — surfaced from the same
    /// poll as the list. Only online Hosts can be created on (create is Host-gated).
    private(set) var hosts: [HostSummary]
    /// Whether the org is on a paid/trialing plan (`host.checkAccess.paidPlan`), the
    /// org-level gate on Host actions. `nil` while undeterminable. Create eligibility
    /// requires this not be a known-false plan, mirroring how delete gates on the
    /// `.planGated` Workspace status (PRD §6.3 — refuse a relay call known to 403).
    private(set) var paidPlan: Bool?
    private(set) var selectedWorkspaceID: Workspace.ID?
    private(set) var loadState: LoadState = .idle
    /// Workspaces with a rename/delete in flight — drives a non-optimistic pending state
    /// on the row (the change is shown only after the next poll confirms it, PRD §7.2).
    private(set) var pendingWorkspaceIDs: Set<Workspace.ID> = []
    /// A create in flight (no row id yet), driving the create sheet's pending state.
    private(set) var isCreatingWorkspace = false
    /// The last lifecycle failure, surfaced to the user and cleared on dismiss/next op.
    private(set) var lifecycleError: String?

    private let provider: WorkspaceListProviding?
    private let lifecycle: WorkspaceLifecycleProviding?
    private let cache: WorkspaceListCaching?
    private let pollInterval: Duration
    private var pollingTask: Task<Void, Never>?
    /// Number of visible windows holding the poll open. Multi-window scenes share this one
    /// store (PRD §13), so polling is reference-counted: it runs while ≥1 window is visible
    /// and stops only when the last closes — a Workspace window restored on its own keeps the
    /// list fresh, so it resolves to content or a 404 rather than a hung spinner (PRD §16.2).
    private var pollingWindowCount = 0
    /// Whether the app is foregrounded. visionOS backgrounds the whole app, so any window
    /// reporting `.active`/inactive gates the shared loop without disturbing the window count.
    private var isForeground = true
    /// Monotonic token guarding against out-of-order applies: a `refresh` only commits
    /// its snapshot if the generation it captured is still current. Bumped on every
    /// refresh start and on `reset`, so a slow in-flight fetch can't clobber newer state
    /// (overlapping polls/retries) or repopulate a list that was just cleared on sign-out.
    private var refreshGeneration: UInt64 = 0

    init(
        provider: WorkspaceListProviding? = nil,
        lifecycle: WorkspaceLifecycleProviding? = nil,
        cache: WorkspaceListCaching? = nil,
        pollInterval: Duration = .seconds(7)
    ) {
        self.provider = provider
        self.lifecycle = lifecycle
        self.cache = cache
        self.pollInterval = pollInterval
        let cached = cache?.load() ?? .empty
        self.projects = cached.projects
        self.workspaces = cached.workspaces
        self.hosts = cached.hosts
        self.paidPlan = cached.paidPlan
    }

    /// The Hosts a new Workspace can be created on — only online Hosts, since create is
    /// Host-gated (the relay forwards only to a reachable Host; ADR-0006).
    var onlineHosts: [HostSummary] {
        hosts.filter(\.online).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Whether lifecycle intents are wired (a real client is injected). The UI hides the
    /// create/rename/delete affordances when false (e.g. the preview/sample store).
    var supportsLifecycle: Bool { lifecycle != nil }

    /// Whether a create may be dialed at `hostID`: lifecycle is wired, the org isn't on a
    /// known-non-paid plan, and that Host is still present in `onlineHosts`. `host.list`
    /// reports physical presence only; the plan gate is a separate `host.checkAccess` read
    /// (carried as `paidPlan`), and the relay enforces both — so an online Host on a
    /// non-active plan must be refused client-side, not dialed. The create sheet can also
    /// outlive a Host going offline (its selected `hostID` goes stale while the poll drops
    /// the Host from `onlineHosts`), so both the UI affordance and the store guard on this
    /// before invoking the relay (create is Host-gated and never queued, per PRD §6.3 /
    /// issue #6). An undeterminable plan (`nil`) is allowed through, matching how delete
    /// gates on the Workspace status — only a known-false plan refuses.
    func canCreate(onHostID hostID: String) -> Bool {
        lifecycle != nil && paidPlan != false && onlineHosts.contains { $0.id == hostID }
    }

    /// Whether a delete may be attempted on `workspace`: lifecycle is wired, the Workspace
    /// has an owning Host, and that Host is currently online on a plan. Delete is Host-gated
    /// (worktree teardown over the relay), so — like create gating on `onlineHosts` — the UI
    /// disables the affordance and the store refuses the relay call for a Workspace it already
    /// knows isn't host-online (`.hostAsleep`/`.planGated`/`.unknown`), per PRD §6.3.
    func canDelete(_ workspace: Workspace) -> Bool {
        lifecycle != nil && workspace.hostID != nil && workspace.status.allowsHostActions
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
            let key = Self.groupKey(for: workspace)
            if names[key] == nil {
                order.append(key)
                names[key] = workspace.projectName.isEmpty ? "Other" : workspace.projectName
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

    /// Dismiss the surfaced lifecycle error (the user acknowledged the alert).
    func clearLifecycleError() {
        lifecycleError = nil
    }

    /// Rename a Workspace (cloud-only, safe Host-offline). Non-optimistic: the row keeps
    /// its old name and shows a pending state until the post-rename poll lands the change.
    /// A no-op when the name is blank or unchanged.
    func rename(_ workspace: Workspace, to newName: String) async {
        guard let lifecycle else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspace.name else { return }
        lifecycleError = nil
        pendingWorkspaceIDs.insert(workspace.id)
        defer { pendingWorkspaceIDs.remove(workspace.id) }
        do {
            try await lifecycle.rename(workspaceID: workspace.id, to: trimmed)
            await refresh()
        } catch {
            lifecycleError = Self.lifecycleMessage(for: error)
        }
    }

    /// Create a Workspace on `hostID`'s Host (Host-gated saga over the relay). Non-optimistic:
    /// the new row appears only after the post-create poll lands it.
    func createWorkspace(projectID: String, name: String, hostID: String) async {
        guard let lifecycle else { return }
        guard canCreate(onHostID: hostID) else {
            lifecycleError = "Host unavailable. The Host must be online and the organization on an active plan to create this workspace."
            return
        }
        lifecycleError = nil
        isCreatingWorkspace = true
        defer { isCreatingWorkspace = false }
        do {
            try await lifecycle.create(projectID: projectID, name: name, hostID: hostID)
            await refresh()
        } catch {
            lifecycleError = Self.lifecycleMessage(for: error)
        }
    }

    /// Delete a Workspace on its Host (Host-gated saga over the relay). A no-op when the
    /// Workspace has no Host (nothing to tear down). Non-optimistic: the row shows a pending
    /// state until the post-delete poll drops it; the selection clears if it was selected.
    func delete(_ workspace: Workspace) async {
        guard let lifecycle, let hostID = workspace.hostID else {
            if workspace.hostID == nil {
                lifecycleError = "This workspace has no Host to delete it from."
            }
            return
        }
        guard workspace.status.allowsHostActions else {
            lifecycleError = "Host unavailable. The Host must be online and the organization on an active plan to delete this workspace."
            return
        }
        lifecycleError = nil
        pendingWorkspaceIDs.insert(workspace.id)
        defer { pendingWorkspaceIDs.remove(workspace.id) }
        do {
            try await lifecycle.delete(workspaceID: workspace.id, hostID: hostID)
            if selectedWorkspaceID == workspace.id { selectedWorkspaceID = nil }
            await refresh()
        } catch {
            lifecycleError = Self.lifecycleMessage(for: error)
        }
    }

    /// Pull one fresh snapshot. Cache-first: a populated list stays on screen while the
    /// poll runs and even if it fails; `loadState` reflects errors for the empty case.
    func refresh() async {
        guard let provider else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if workspaces.isEmpty { loadState = .loading }
        do {
            let snapshot = try await provider.fetchSnapshot()
            guard generation == refreshGeneration else { return }
            apply(snapshot)
            cache?.save(snapshot)
            loadState = .loaded
        } catch is CancellationError {
            // Polling was cancelled (hidden/backgrounded) — keep the last good data.
        } catch {
            guard generation == refreshGeneration else { return }
            loadState = workspaces.isEmpty ? .failed(Self.message(for: error)) : .loaded
        }
    }

    /// Drop all signed-in state and the durable cache. Called on sign-out so the next
    /// account/org never paints the previous one's Workspaces (privacy + correctness):
    /// polling stops, the generation bumps so any in-flight fetch is discarded, the
    /// in-memory list and selection clear, and the cache file is removed.
    func reset() {
        stopPolling()
        refreshGeneration &+= 1
        projects = []
        workspaces = []
        hosts = []
        paidPlan = nil
        pendingWorkspaceIDs = []
        isCreatingWorkspace = false
        lifecycleError = nil
        selectedWorkspaceID = nil
        loadState = .idle
        cache?.clear()
    }

    /// A newly-visible window joins the shared poll. Reference-counted so multiple windows
    /// keep one loop alive; balanced by `endPolling` on disappear.
    func beginPolling() {
        pollingWindowCount += 1
        ensurePolling()
    }

    /// A window disappearing leaves the shared poll; the loop stops once the last window is
    /// gone. Clamped at zero so an unbalanced extra call can't drive the count negative.
    func endPolling() {
        pollingWindowCount = max(0, pollingWindowCount - 1)
        if pollingWindowCount == 0 { stopPolling() }
    }

    /// Report app foreground state. Backgrounding pauses the loop without changing the window
    /// count (ADR-0004); foregrounding resumes it if any window is still visible.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            ensurePolling()
        } else {
            stopPolling()
        }
    }

    /// Start the shared loop when a window is visible and the app is foregrounded. Idempotent —
    /// a second call while a loop is running is a no-op.
    private func ensurePolling() {
        guard provider != nil, pollingTask == nil, pollingWindowCount > 0, isForeground else { return }
        let interval = pollInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                if Task.isCancelled { break }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Cancel the shared loop (last window closed or app backgrounded). The window count is
    /// left untouched so a later foreground can resume while windows are still open.
    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func apply(_ snapshot: WorkspaceListSnapshot) {
        projects = snapshot.projects
        workspaces = snapshot.workspaces
        hosts = snapshot.hosts
        paidPlan = snapshot.paidPlan
        if let selectedWorkspaceID, !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            self.selectedWorkspaceID = nil
        }
    }

    /// Bucket key for a Workspace: its `projectID` when present, else its embedded
    /// `projectName` (so Project-less Workspaces sharing a name group together), else a
    /// single ungrouped bucket. The prefixes can't collide with server-issued ids.
    private static func groupKey(for workspace: Workspace) -> String {
        if let projectID = workspace.projectID { return projectID }
        return workspace.projectName.isEmpty
            ? ungroupedKey
            : "\(embeddedKeyPrefix)\(workspace.projectName)"
    }

    private static let ungroupedKey = "__ungrouped"
    private static let embeddedKeyPrefix = "__embedded:"

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

    /// User-facing copy for a failed lifecycle op. A relay 403 means the Host is offline or
    /// the org's plan doesn't allow host access (`checkHostAccess`), the dominant failure for
    /// the Host-gated create/delete — surfaced plainly rather than as a raw status.
    private static func lifecycleMessage(for error: Error) -> String {
        switch error {
        case AuthError.notAuthenticated:
            return "Not signed in."
        case AuthError.noActiveOrganization:
            return "No organization available."
        case AuthError.badServerResponse(status: 403):
            return "Host unavailable. The Host must be online and the organization on an active plan."
        case let AuthError.badServerResponse(status):
            return "The operation failed (HTTP \(status)). Please try again."
        default:
            return "The operation failed. Please try again."
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
    /// A `WorkspaceListCaching` that returns a fixed snapshot seeds the store on init; a
    /// no-op lifecycle wires the create/rename/delete affordances so they render in previews.
    static func sample() -> WorkspaceStore {
        WorkspaceStore(lifecycle: SampleLifecycle(), cache: SampleCache())
    }

    private struct SampleCache: WorkspaceListCaching {
        func load() -> WorkspaceListSnapshot? {
            WorkspaceListSnapshot(
                projects: [Project(id: "p-superset", name: "superset")],
                workspaces: [
                    Workspace(id: "ws-auth", name: "auth-handoff", projectID: "p-superset", projectName: "superset", status: .hostOnline, hostID: "host-1"),
                    Workspace(id: "ws-relay", name: "relay-tunnel", projectID: "p-superset", projectName: "superset", status: .planGated, hostID: "host-1"),
                    Workspace(id: "ws-vision", name: "vision-pro-app", projectID: "p-superset", projectName: "superset", status: .hostAsleep, hostID: "host-1"),
                ],
                hosts: [HostSummary(id: "host-1", name: "studio-mac", online: true)],
                paidPlan: true
            )
        }

        func save(_ snapshot: WorkspaceListSnapshot) {}

        func clear() {}
    }

    private struct SampleLifecycle: WorkspaceLifecycleProviding {
        func rename(workspaceID: String, to name: String) async throws {}
        func create(projectID: String, name: String, hostID: String) async throws {}
        func delete(workspaceID: String, hostID: String) async throws {}
    }
}
