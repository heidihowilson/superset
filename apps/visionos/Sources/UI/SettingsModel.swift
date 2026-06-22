import Foundation
import Observation

/// Cloud-backed state for the Settings window — the read-only account/org surface plus
/// the one cloud-persisted editable: the active organization (PRD §7.2, ADR-0005).
/// Loads the better-auth session, the org memberships, and the cloud model list (the
/// preferred-model picker's options) through the shared bearer seam; switching the
/// active org is a session change that needs no re-auth.
///
/// Presentation-agnostic, like `WorkspaceStore`: the view observes it and emits intents.
@MainActor
@Observable
final class SettingsModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The "Verify host credential" probe: mints the relay JWT that host-service-over-relay
    /// calls present (PRD §13). The minted token is never stored or surfaced — only the
    /// success/failure outcome.
    enum RelayProbe: Equatable {
        case idle
        case running
        case minted
        case failed(String)
    }

    private(set) var session: SessionInfo?
    private(set) var organizations: [OrganizationSummary] = []
    /// Cloud chat models, the preferred-model picker's options. Best-effort: an empty
    /// list (load failed or none offered) leaves only the "Automatic" choice.
    private(set) var models: [ChatModel] = []
    private(set) var loadState: LoadState = .idle
    /// An active-org switch in flight, driving the picker's pending/disabled state.
    private(set) var isSwitchingOrganization = false
    private(set) var switchError: String?
    /// Outcome of the most recent "Verify host credential" probe.
    private(set) var relayProbe: RelayProbe = .idle

    private let api: AuthAPIClient

    init(api: AuthAPIClient) {
        self.api = api
    }

    var activeOrganizationID: String? { session?.activeOrganizationID }

    var activeOrganizationName: String? {
        guard let activeOrganizationID else { return nil }
        return organizations.first { $0.id == activeOrganizationID }?.name
    }

    /// Load the account/org surface and the model picker's options. Session + orgs are
    /// required (their failure surfaces the error state); models are best-effort and
    /// never block. All three are awaited on every path so no `async let` is abandoned.
    func load() async {
        if loadState != .loaded { loadState = .loading }
        async let sessionResult = api.fetchSession()
        async let orgsResult = api.listOrganizations()
        async let modelsResult = api.fetchChatModels()

        let session = try? await sessionResult
        let organizations = try? await orgsResult
        models = (try? await modelsResult) ?? []

        if let session, let organizations {
            self.session = session
            self.organizations = organizations
            loadState = .loaded
        } else {
            loadState = .failed("Couldn't load settings. Check your connection and try again.")
        }
    }

    /// Switch the session's active organization (cloud-persisted, no re-auth — ADR-0005),
    /// then reload the session so the active selection reflects the server's truth. A
    /// no-op when the target is already active.
    func switchOrganization(to id: String) async {
        guard id != activeOrganizationID else { return }
        switchError = nil
        isSwitchingOrganization = true
        defer { isSwitchingOrganization = false }
        do {
            try await api.setActiveOrganization(id: id)
            session = try await api.fetchSession()
        } catch {
            switchError = Self.message(for: error)
        }
    }

    /// Mint the relay JWT to prove the bearer session can obtain a host credential
    /// (PRD §13). The token is discarded — only the success/failure outcome is kept.
    func mintRelayCredential() async {
        relayProbe = .running
        do {
            _ = try await api.mintRelayJWT()
            relayProbe = .minted
        } catch {
            relayProbe = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AuthError.notAuthenticated:
            return "Not signed in."
        case AuthError.noActiveOrganization:
            return "No organization available."
        case let AuthError.badServerResponse(status):
            return "Server returned HTTP \(status)."
        default:
            return "Something went wrong. Please try again."
        }
    }
}
