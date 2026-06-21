import SwiftUI

/// Gates the app on a Keychain session token (M0a). Signed out → `SignInView`;
/// signed in → the existing `RootView` (the M0 renderer seam) flanked by a session
/// connectivity check (which exercises the bearer seams) and a Sign Out affordance.
/// The `loading` flash while the Keychain is read is intentionally minimal — a
/// progress view, not a redirect.
///
/// Also the deep-link entry point (PRD §16.2): `superset://auth/callback` completes the
/// OAuth handoff; `workspace`/`project`/`session` links open the target window. A link
/// that arrives signed-out is held as `pendingRoute` and replayed once sign-in lands
/// (cold-start intent, PRD §11). Injects the interaction-model registry and the
/// open-windows roster into the environment so the switcher/list/window controls share
/// one instance of each.
struct AuthGateView: View {
    let auth: AuthController
    let store: WorkspaceStore
    let models: InteractionModelRegistry
    let openWindows: OpenWindowsModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pendingRoute: DeepLinkRoute?

    var body: some View {
        content
            .environment(models)
            .environment(openWindows)
            .onAppear { auth.restore() }
            .onOpenURL { handle($0) }
            // Replay a deep link that arrived signed-out once sign-in lands. The
            // signed-out cache reset lives on `AuthController.onSignedOut` (wired in
            // `SupersetApp`), not here, so it fires on every sign-out path even when
            // this scene is closed and only Settings is on screen.
            .onChange(of: auth.status) { _, status in
                if status == .signedIn {
                    flushPendingRoute()
                }
            }
    }

    /// Route a `superset://` deep link. Auth callbacks always go to `AuthController`
    /// (they may arrive mid-handoff); content links open immediately when signed in,
    /// else wait as `pendingRoute` for the post-sign-in replay.
    private func handle(_ url: URL) {
        guard let route = DeepLinkRouter.route(url) else { return }
        switch route {
        case .authCallback:
            auth.handleDeepLink(url)
        default:
            if auth.status == .signedIn {
                open(route)
            } else {
                pendingRoute = route
            }
        }
    }

    private func flushPendingRoute() {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        open(route)
    }

    private func open(_ route: DeepLinkRoute) {
        WindowRouter.open(
            route,
            store: store,
            models: models,
            openWindows: openWindows,
            openWindow: openWindow,
            dismissWindow: dismissWindow
        )
    }

    @ViewBuilder
    private var content: some View {
        switch auth.status {
        case .loading:
            ProgressView()
        case .signedIn:
            RootView(store: store)
                .ornament(attachmentAnchor: .scene(.topLeading)) {
                    SessionStatusView(client: auth.makeAPIClient())
                }
                .ornament(attachmentAnchor: .scene(.topTrailing)) {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                        auth.signOut()
                    }
                    .padding()
                    .glassBackgroundEffect()
                }
        case .signedOut, .authenticating, .failed:
            SignInView(controller: auth)
        }
    }
}
