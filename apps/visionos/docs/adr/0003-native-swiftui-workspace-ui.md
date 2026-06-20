# 0003 — Native SwiftUI workspace UI (supersedes ADR-0001)

**Status:** accepted (supersedes ADR-0001)

The existing `app.superset.sh` workspace experience is an unusable proof-of-concept, so the V1 workspace UI must be built fresh regardless of technology. Given that the hybrid's headline benefit (reusing existing web UI) no longer exists, V1 builds a **native SwiftUI/RealityKit** workspace UI rather than WKWebView-hosted web panes — chosen for headset-appropriate comfort (gaze/pinch, glass materials, performance) and a clean path to V2 spatial volumes with no web→RealityKit rewrite. We will not fix the web app's workspace UI to serve visionOS.

## Consequences

- **Re-incurs** the costs ADR-0001 had dissolved: a native Swift Electric/TanStack-DB sync client (R-SYNC) + the M0-Sync hardware gate, TS→Swift wire-contract codegen (R-CODEGEN), and pane-data extraction (WI-CORE-2). The thin-shell "no native Electric client" stance is reversed; the native/web seam (ADR-0001) no longer applies.
- Host calls (diff/file/comment/create/terminal) are **reimplemented natively** against the relay→host-service HTTP/WS endpoints — reimplementation, not invention: the protocol is proven by `apps/web/src/trpc/host-client.ts` and the `WebTerminal` transport.
- **ADR-0002 (cookie-session auth) is preserved**: native holds the session cookie and mints the Electric/relay JWT from `/api/auth/token`, so the four-verifier / PKCE-spike simplification still stands.
- The web app's *plumbing* (relay path, JWT minting, terminal/stream transport shapes) remains a reference implementation for the native client to mirror.
- Electron and a Node/Bun runtime on device remain excluded.
