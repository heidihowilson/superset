# Phase 2 — Integrated terminal: the relay transport

**Status:** planned (2026-06-26)
**Depends on:** Phase 1 (TerminalSurface integration — proven on `feat/terminal-surface`, renders + echoes via `LoopbackTerminalIO`).
**Goal:** drive the `TerminalSurface` from a **real host PTY over the relay** instead of a loopback echo, so a Workspace's terminal session renders live in the visionOS client.
**Out of scope:** Phase 3 (the product UX — replacing the chat session view, multi-terminal window/rail model, session discovery UI). This phase ends when a real terminal session streams into one window, manual-test-ready behind the existing Debug/spike entry point.

## What already exists (no backend work)

The desktop **and** web clients already drive the terminal over a raw binary WebSocket on the **same relay** the visionOS app authenticates to:

```
wss://{relay}/hosts/{routingKey}/terminal/{terminalId}?workspaceId=…&token={relayJWT}
  binary frames           = live PTY output            (render these)
  JSON {type:"input",data}        = keystrokes          (client → host)
  JSON {type:"resize",cols,rows}  = grid change         (client → host)
  JSON {type:"attached"|"title"|"exit"|"error"}         = control (host → client)
```

- Relay path: the generic `/hosts/:hostId/*` WebSocket proxy (Transport B), distinct from the unary tRPC-over-HTTP path (Transport A) our `HostServiceClient` uses today. Defined in `apps/relay/src/index.ts` (`upgradeWebSocket`), host side `packages/host-service/src/terminal/terminal.ts` (`registerWorkspaceTerminalRoute`).
- PTY lives in `packages/pty-daemon` (node-pty), bridged to the WS by host-service. **Nothing about the byte stream is Electron-specific.**
- Already low-latency: `TCP_NODELAY` on every relay hop (named for terminals), binary frames, a per-session replay ring-buffer for reattach.
- `terminalId` (a UUID) is the session id; sessions are created via tRPC `terminal.createSession` / `agents.run` (unary — the path we already speak) and listed via `terminal.listSessions`.
- visionOS already holds the three ingredients: the `RelayTokenProvider` JWT, the `routingKey` (`buildHostRoutingKey(orgId, machineId)`), and the relay base URL. The JWT rides in the WS **query string** (a WS limitation the relay accommodates).

**Reference implementation to port:** `apps/web/src/app/workspaces/[workspaceId]/components/WebTerminal/TerminalConnection.ts` — almost line-for-line what our Swift `RelayTerminalIO` needs to be.

## The gate: package distribution (P0)

The TerminalSurface package is consumed via `.package(path: "/Users/sethgho/ghv-spike/TerminalSurface")` with a **gitignored, locally-staged xcframework**. That only resolves on Seth's Mac — GitHub CI (and any other machine) can't build it, so merging Phase 1 (or looping Phase 2) on `vision-pro-app` turns CI red and the loop's merge gate (CodeRabbit + CI green) never fires.

**P0 (package-side, filed on `heidihowilson/ghostty-visionos`, watch-to-close):** publish a versioned release with the **checksummed `Libghostty.xcframework`** and make the package **URL-consumable** (repo-root package or registry), so Superset can depend via `.package(url:…)` + `.binaryTarget(url:checksum:)` and CI/SwiftPM resolve it with no local staging. INTEGRATION.md §0 already anticipates this switch.

Once P0 lands: switch `project.yml` to the URL/checksum form, merge `feat/terminal-surface` → `vision-pro-app` (CI green), then the Phase-2 slices loop normally on `vision-pro-app`.

## Implementation slices (loop-ready, dependency-ordered)

All target `vision-pro-app` and are **blocked until P0 + the Phase-1 merge**.

1. **T1 — Connectivity spike (de-risk first).** Provision a real terminal session on a live host and open a `URLSessionWebSocketTask` to `wss://{relay}/hosts/{routingKey}/terminal/{id}?workspaceId=&token=`; log received bytes. Proves the one empirical unknown: that a visionOS WS authenticates + streams through the relay (token-in-query, Fly affinity, host-service WS auth). No emulator needed — just bytes to the log. Behind Debug.
2. **T2 — Session provisioning.** Add `terminal.createSession` + `terminal.listSessions` to `HostServiceClient` (unary, same path it already uses). Returns/lists `terminalId` for a workspace.
3. **T3 — `RelayTerminalIO`** implementing the package's `TerminalIO`: a `URLSessionWebSocketTask` mapping `.data` frames → the `output` `AsyncStream<Data>`, and `send`/`resize` → JSON `{type:"input"}`/`{type:"resize"}` text frames. **Must be thread-safe** — the package now delivers callbacks off-main on the termio thread, serially (ghostty-visionos#2 contract). A WS task with its own delegate/queue fits this naturally.
4. **T4 — Affinity preflight.** `GET /hosts/{routingKey}/_whoowns` before the WS upgrade to lock Fly edge affinity (mirrors the web/desktop `primeRelayAffinity`).
5. **T5 — Wire it up.** Replace `LoopbackTerminalIO` in the terminal window with `RelayTerminalIO` bound to a provisioned session; map `TerminalSurfaceController.gridSize`/resize → `{type:"resize"}`. Keep it behind the Debug/spike entry point.
6. **T6 — Reconnect + replay + lifecycle.** Handle `attached`/`exit`/`error` control frames, the `?replay=0` after first bytes, and reconnect on drop (the host keeps a replay buffer).
7. **T7 — Tests.** Unit-cover the control-message codec (input/resize encode, attached/exit/error decode) and a `RelayTerminalIO` drive test against a stub WebSocket. Keep the UITest harness from Phase 1.

## Acceptance (manual-test-ready)

Building green for sim + device under Swift 6 strict concurrency, and on the Simulator (or device, against a live host with a terminal session): the terminal window renders the **real shell**, keystrokes reach the PTY and echo back, and resize reflows. Behind the Debug entry point — production UX is Phase 3.

## Caveats (carried from scoping)

- Live IO is **WebSocket-only** — create/list/kill are tRPC, but output streaming + resize are the raw WS. No all-tRPC option.
- JWT-in-URL for the WS is by design (short-lived relay token).
- Adopted-session resize after a daemon-binary upgrade is best-effort kernel-side (minor fidelity gap, not a blocker).
- The relay token is short-lived; `RelayTerminalIO` should reconnect with a freshly-minted JWT (reuse `RelayTokenProvider`).
