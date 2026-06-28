import Foundation

/// Builds the relay terminal URLs from a resolved routing key + terminal id, mirroring the
/// web client's `buildUrl`/`primeRelayAffinity` (`apps/web/.../WebTerminal/TerminalConnection.ts`,
/// `packages/workspace-client/.../primeRelayAffinity.ts`). Pure value type so the URL shaping
/// is unit-testable without a socket.
struct RelayTerminalEndpoint: Sendable {
    /// `NEXT_PUBLIC_RELAY_URL` (https). The WS URL swaps the scheme to `wss`.
    let relayBaseURL: URL
    /// `organizationId:machineId` — the relay tunnel key (same shape `HostServiceClient` uses).
    let routingKey: String
    let terminalId: String
    let workspaceID: String

    /// `wss://{relay}/hosts/{routingKey}/terminal/{terminalId}?workspaceId=…&themeType=dark&token=…`.
    /// The JWT rides in the query string (browsers can't set WS upgrade headers; the relay
    /// reads `?token=`). `replay=0` is appended once bytes have been seen, to skip the host's
    /// ring-buffer re-dump on reattach — T6 (reconnect) is the only caller that sets it.
    func webSocketURL(token: String, replay: Bool = true) -> URL? {
        guard var components = URLComponents(url: relayBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = relayBaseURL.scheme == "http" ? "ws" : "wss"
        let encodedTerminal = terminalId
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? terminalId
        components.path = "/hosts/\(routingKey)/terminal/\(encodedTerminal)"
        var items = [
            URLQueryItem(name: "workspaceId", value: workspaceID),
            URLQueryItem(name: "themeType", value: "dark"),
            URLQueryItem(name: "token", value: token),
        ]
        if !replay { items.append(URLQueryItem(name: "replay", value: "0")) }
        components.queryItems = items
        return components.url
    }

    /// `https://{relay}/hosts/{routingKey}/_whoowns?token=…&workspaceId=…` — the plain-HTTP
    /// affinity probe. fly-replay is transparent for HTTP (not for the WS upgrade), so this GET
    /// locks Fly's edge affinity to the owning machine before the socket dials, avoiding the
    /// connect→1006→reconnect flicker. The token is kept so the relay can authenticate it.
    func whoOwnsURL(token: String) -> URL? {
        guard var components = URLComponents(url: relayBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/hosts/\(routingKey)/_whoowns"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "workspaceId", value: workspaceID),
        ]
        return components.url
    }
}

/// Best-effort Fly edge-affinity preflight: a short, cache-busting GET to `_whoowns` so the
/// follow-up WS upgrade lands on the machine that owns the tunnel (mirrors the web's
/// `primeRelayAffinity`). Failures are swallowed — the socket still dials, it may just
/// briefly flicker through an implicit retry.
func primeRelayTerminalAffinity(url: URL, http: HTTPPerforming) async {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 3
    _ = try? await http.data(for: request)
}

/// Provisions and attaches a Phase-2 relay terminal for one Workspace: resolves the org →
/// routing key, mints the relay JWT, creates the host-side PTY session (`terminal.createSession`),
/// primes Fly affinity, then opens the WS and wraps it in a started `RelayTerminalIO`. The
/// production wiring counterpart to `HostChatTranscriptProvider` for the terminal seam (Debug
/// only — not on the production rail).
///
/// An `actor` to memoize the resolved org id across calls, exactly like the chat/lifecycle
/// providers. The WS task is built by an injected factory so the `URLSession` dependency stays
/// at the edge and the connect path is exercised without real networking in tests.
actor RelayTerminalSessionProvider {
    private let api: AuthAPIClient
    private let configuration: AuthConfiguration
    private let http: HTTPPerforming
    private let tokenProvider: RelayTokenProvider
    private let makeWebSocketTask: @Sendable (URL) -> TerminalWebSocketTask
    private let workspaceID: String
    private let hostID: String

    private var resolvedOrganizationID: String?

    /// The attached transport plus the host's terminal id (for reattach/diagnostics).
    struct Connection: Sendable {
        let terminalId: String
        let io: RelayTerminalIO
    }

    init(
        api: AuthAPIClient,
        configuration: AuthConfiguration,
        http: HTTPPerforming,
        tokenProvider: RelayTokenProvider,
        workspaceID: String,
        hostID: String,
        makeWebSocketTask: @escaping @Sendable (URL) -> TerminalWebSocketTask
    ) {
        self.api = api
        self.configuration = configuration
        self.http = http
        self.tokenProvider = tokenProvider
        self.workspaceID = workspaceID
        self.hostID = hostID
        self.makeWebSocketTask = makeWebSocketTask
    }

    func connect(
        onControl: @escaping @Sendable (TerminalControlMessage) -> Void = { _ in }
    ) async throws -> Connection {
        let organizationID = try await resolveOrganizationID()
        let routingKey = "\(organizationID):\(hostID)"

        let client = HostServiceClient(
            configuration: configuration,
            http: http,
            tokenProvider: tokenProvider,
            routingKey: routingKey
        )
        let terminalId = try await client.createTerminalSession(workspaceID: workspaceID)

        let token = try await tokenProvider.token()
        let endpoint = RelayTerminalEndpoint(
            relayBaseURL: configuration.relayBaseURL,
            routingKey: routingKey,
            terminalId: terminalId,
            workspaceID: workspaceID
        )
        guard let socketURL = endpoint.webSocketURL(token: token) else {
            throw AuthError.badServerResponse(status: -1)
        }

        // T4: prime Fly edge affinity over plain HTTP before the WS upgrade.
        if let whoOwns = endpoint.whoOwnsURL(token: token) {
            await primeRelayTerminalAffinity(url: whoOwns, http: http)
        }

        let task = makeWebSocketTask(socketURL)
        let io = RelayTerminalIO(task: task, onControl: onControl)
        io.start()
        return Connection(terminalId: terminalId, io: io)
    }

    /// The org the Workspace's Host is keyed under — the session's active org, else the user's
    /// first membership (the same resolution the watch/send/list paths use). Cached after the
    /// first call so the routing key is built without a per-connect session read.
    private func resolveOrganizationID() async throws -> String {
        if let resolvedOrganizationID { return resolvedOrganizationID }
        let session = try await api.fetchSession()
        if let id = session.activeOrganizationID {
            resolvedOrganizationID = id
            return id
        }
        if let first = try await api.listOrganizations().first {
            resolvedOrganizationID = first.id
            return first.id
        }
        throw AuthError.noActiveOrganization
    }
}
