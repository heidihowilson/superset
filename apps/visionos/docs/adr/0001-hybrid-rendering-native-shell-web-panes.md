# 0001 — Hybrid rendering: native shell, WKWebView content panes

**Status:** superseded by ADR-0003 (the existing web workspace UI proved unusable, so V1 builds native UI instead of reusing web panes)

V1 renders content panes (chat, diff, file, comment) as `WKWebView`-hosted React behind the `PaneRenderer` protocol, inside a native SwiftUI/RealityKit shell — not full-native SwiftUI. We chose this because reusing the existing web renderer reuses the JS sync/auth/UI stack wholesale, dissolving three V1-blocking cost centers (a native Swift Electric/TanStack-DB client, chat-stream bearer auth, and TS→Swift wire-contract codegen). The accepted cost is spatial debt — flat web panes can never become RealityKit volumes, so they must be re-implemented natively for V2+ — which is tolerable only because each pane is a swappable `PaneRenderer` implementation, migrated per-kind on the spatial roadmap.

## Consequences

- The native/web seam is fixed: **shell, windowing, and chrome are native; pane content is web.** A single app-wide webview wrapper (no native shell) is explicitly rejected — that forfeits the window-per-domain capability and the spatial future.
- Electron and a Node/Bun runtime on device remain impossible/excluded; this is WebKit + web assets only.
- Enables ADR-0002 (a hybrid app is not cookieless).
- **No native Swift Electric/TanStack-DB client in V1.** All live-data surfaces (chat, workspace browser, status, diff/file) are web; the native shell owns only scene/window lifecycle, ornament chrome, dictation, deep-link routing, auth/session bootstrap, and a lightweight cookie-authed `v2Workspace.list` query for the switcher. This dissolves the M0-Sync hardware gate and R-SYNC for V1, and shrinks `superset-core`/codegen to near-nothing.
