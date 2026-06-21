import SwiftUI

/// The M0a connectivity check: proves the Keychain bearer token actually drives the
/// cloud seams rather than sitting unused. On appear it reads the session
/// (`fetchSession`) and the user's orgs (`listOrganizations`); switching the active
/// org calls `setActiveOrganization` and re-reads — demonstrating an org switch with
/// no re-auth (PRD §11 acceptance). "Verify host credential" mints the relay JWT
/// (`mintRelayJWT`) the host-service-over-relay calls present; the minted token is
/// never shown or logged (§13).
struct SessionStatusView: View {
    let client: AuthAPIClient

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private enum RelayProbe: Equatable {
        case idle
        case running
        case minted
        case failed(String)
    }

    @State private var session: SessionInfo?
    @State private var organizations: [OrganizationSummary] = []
    @State private var loadState: LoadState = .loading
    @State private var relayProbe: RelayProbe = .idle
    @State private var isSwitching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Session", systemImage: "person.badge.key")
                .font(.headline)

            switch loadState {
            case .loading:
                ProgressView()
            case let .failed(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.bordered)
            case .loaded:
                loaded
            }
        }
        .padding()
        .frame(maxWidth: 320, alignment: .leading)
        .glassBackgroundEffect()
        .task { await load() }
    }

    @ViewBuilder
    private var loaded: some View {
        if let email = session?.userEmail {
            Text(email)
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        HStack(spacing: 6) {
            Text("Active org:")
                .foregroundStyle(.secondary)
            Text(activeOrganizationName)
            if isSwitching { ProgressView().controlSize(.small) }
        }
        .font(.callout)

        if organizations.count > 1 {
            Menu("Switch org") {
                ForEach(organizations) { org in
                    Button {
                        Task { await switchOrganization(to: org.id) }
                    } label: {
                        if org.id == session?.activeOrganizationID {
                            Label(org.name, systemImage: "checkmark")
                        } else {
                            Text(org.name)
                        }
                    }
                }
            }
            .disabled(isSwitching)
        }

        Button("Verify host credential") {
            Task { await mintRelayCredential() }
        }
        .buttonStyle(.bordered)
        .disabled(relayProbe == .running)

        relayStatus
    }

    @ViewBuilder
    private var relayStatus: some View {
        switch relayProbe {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .minted:
            Label("Relay credential minted", systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private var activeOrganizationName: String {
        guard let id = session?.activeOrganizationID else { return "none" }
        return organizations.first { $0.id == id }?.name ?? id
    }

    private func load() async {
        loadState = .loading
        do {
            session = try await client.fetchSession()
            organizations = (try? await client.listOrganizations()) ?? []
            loadState = .loaded
        } catch {
            loadState = .failed(Self.message(for: error))
        }
    }

    private func switchOrganization(to id: String) async {
        guard id != session?.activeOrganizationID else { return }
        isSwitching = true
        defer { isSwitching = false }
        do {
            try await client.setActiveOrganization(id: id)
            session = try await client.fetchSession()
        } catch {
            loadState = .failed(Self.message(for: error))
        }
    }

    private func mintRelayCredential() async {
        relayProbe = .running
        do {
            _ = try await client.mintRelayJWT()
            relayProbe = .minted
        } catch {
            relayProbe = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AuthError.notAuthenticated:
            return "Not signed in."
        case let AuthError.badServerResponse(status):
            return "Server returned HTTP \(status)."
        default:
            return "Connectivity check failed. Please try again."
        }
    }
}
