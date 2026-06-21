import Foundation

/// A parsed `superset://` deep link, mapped to the `(sceneKind, domainId)` grammar the
/// app routes on (PRD §16.2). Value-keyed scenes turn a `.workspace`/`.project` route
/// into open-or-focus for free; `.authCallback` is handed back to `AuthController`
/// (the OAuth handoff, ADR-0005) rather than opening a content window.
enum DeepLinkRoute: Equatable {
    case workspace(Workspace.ID)
    case project(Project.ID)
    /// A chat session id (`ADR-0010`). V1 resolves it to the Workspace that owns the
    /// session *on this device* (the only session→Workspace index that exists);
    /// cross-client discovery is V2, so a foreign session id has no scene.
    case session(String)
    /// `superset://auth/callback?token=…` — the bearer handoff, validated by
    /// `AuthController`, not a content scene.
    case authCallback(URL)
}

/// Pure parser for the `superset://` URL grammar (PRD §16.2). The host names the scene
/// kind; the first path component is the domain id. Returns `nil` for anything outside
/// the grammar so callers can ignore unrelated URLs.
enum DeepLinkRouter {
    static let scheme = "superset"

    static func route(_ url: URL) -> DeepLinkRoute? {
        guard url.scheme == scheme else { return nil }
        switch url.host(percentEncoded: false) {
        case "auth":
            return .authCallback(url)
        case "workspace":
            return firstPathComponent(of: url).map(DeepLinkRoute.workspace)
        case "project":
            return firstPathComponent(of: url).map(DeepLinkRoute.project)
        case "session":
            return firstPathComponent(of: url).map(DeepLinkRoute.session)
        default:
            return nil
        }
    }

    /// The leading non-separator path component (`superset://workspace/<id>` → `<id>`),
    /// or `nil` when the id is missing so a malformed link doesn't open an empty scene.
    private static func firstPathComponent(of url: URL) -> String? {
        url.pathComponents.first { $0 != "/" && !$0.isEmpty }
    }
}
