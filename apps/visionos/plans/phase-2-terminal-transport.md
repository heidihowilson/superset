# Phase 2 — Terminal relay transport (visionOS)

Wire the Phase-1 `TerminalSurface` package (loopback-proven) to a **real host PTY over the
relay**, so a signed-in Vision Pro session can drive a live terminal. Phase 1 integrated the
package behind a Debug spike window with `LoopbackTerminalIO`; Phase 2 adds the relay transport
alongside it, behind the same Debug surface — **not** the production rail.

## Transport shape (mirrors the web client)

The web reference is `apps/web/src/app/workspaces/[workspaceId]/components/WebTerminal/TerminalConnection.ts`
plus `apps/web/src/trpc/host-client.ts`. We mirror it byte-for-byte at the wire boundary:

- **Provisioning** (unary tRPC over the relay, same path/JWT as `HostServiceClient`):
  - `terminal.createSession({ workspaceId }) → { terminalId, status }` (POST)
  - `terminal.listSessions({ workspaceId }) → { sessions: HostTerminalSession[] }` (GET)
- **Attach** (WebSocket): `wss://{relay}/hosts/{routingKey}/terminal/{terminalId}?workspaceId=…&themeType=dark&token={relayJWT}`
  - JWT rides in the **query string** (a WS upgrade can't carry an `Authorization` header).
  - Inbound **binary** frames = raw PTY output → rendered by the surface.
  - Inbound **text** frames = control JSON: `{"type":"attached"|"title"|"exit"|"error"}`.
  - Outbound **text** frames: `{"type":"input","data":…}` / `{"type":"resize","cols":…,"rows":…}`.
- **Affinity preflight** (T4): a plain-HTTP `GET /hosts/{routingKey}/_whoowns?token=…` before the
  WS upgrade, to lock Fly edge affinity to the owning machine (mirrors `primeRelayAffinity`).

`routingKey` is `"{organizationId}:{hostId}"` — the same key `HostServiceClient` already builds.

## Slices

- [x] **T2 — session provisioning.** `HostServiceClient.createTerminalSession(workspaceID:)` and
  `.listTerminalSessions(workspaceID:)` (unary, same relay path/JWT/SuperJSON envelope it already
  uses; tolerant `HostTerminalSession` decode). — `Sources/Cloud/HostServiceClient.swift`
- [x] **T3 — `RelayTerminalIO`.** Implements the package's `TerminalIO` over a
  `URLSessionWebSocketTask` (behind the `TerminalWebSocketTask` protocol so it's testable against a
  stub). Binary → `output` stream; `send`/`resize` → ordered outbound text frames (a single writer
  task drains a FIFO `AsyncStream`, so the off-main-actor, serialized termio calls stay in order
  without holding a lock across the network); inbound control frames decode to an `onControl`
  handler. Thread-safe / `@unchecked Sendable`. Codec is a pure value type (`TerminalWireMessage`).
  — `Sources/Terminal/RelayTerminalIO.swift`, `TerminalWireMessage.swift`
- [x] **T4 — affinity preflight.** `RelayTerminalEndpoint` builds the `wss` + `_whoowns` URLs;
  `primeRelayTerminalAffinity` does the best-effort GET before the socket dials.
  — `Sources/Terminal/RelayTerminalSession.swift`
- [x] **T5 — wire-up (Debug only).** `RelayTerminalSessionProvider` (actor) resolves the org →
  routing key, provisions the session, mints the JWT, primes affinity, opens the WS, and returns a
  started `RelayTerminalIO`. The Terminal spike window gains a **Loopback / Live** mode picker; Live
  mode offers a Workspace picker (Workspaces with a Host), connects, attaches the transport to a
  `TerminalSurfaceController`, and seeds the PTY at the surface's grid size. The loopback spike is
  untouched. — `Sources/UI/TerminalWindow.swift`, `AuthController.makeTerminalSessionProvider`,
  `SupersetApp.swift`

## Build / test status

- Builds **green** for `-sdk xrsimulator` and `-sdk xros` (scheme `Superset`), Swift 6 strict
  concurrency, zero new warnings.
- Unit tests (all green): `TerminalWireMessageTests` (codec encode/decode), `RelayTerminalIOTests`
  (drive against a stubbed `TerminalWebSocketTask`: bytes→output, send/resize→frames, ordering,
  control decode, close/error), `RelayTerminalEndpointTests` (URL shaping), and
  `HostServiceClientTerminalTests` (create/list request shape + tolerant decode).
- `TerminalSpikeUITests` (Phase-1 loopback) still passes — no regression.

> **Build note:** build/test with `xcodebuild -scheme Superset` (NOT `-target Superset`). Under
> Xcode 26.4's explicit-module build, the `-target` form fails the dependency scan with
> "unable to resolve module dependency: 'TerminalSurface'"; `-scheme` builds the package product
> in the right order and resolves it. The smoke-test script already uses `-scheme`.

## Remaining

- [ ] **T6 — reconnect / replay.** Exponential-backoff reconnect on an unexpected close, plus
  `replay=0` once bytes have been seen (the web's visibility/online-driven recovery). `RelayTerminalIO`
  currently finishes `output` on close/error; reconnect is not yet wired.
- [ ] **T7 — broader tests.** A `RelayTerminalSessionProvider.connect` test against stubbed HTTP +
  a stub WS factory (org resolve → createSession → affinity → attach), and an affinity-preflight test.
- [ ] **Human connectivity test** (cannot be automated — needs a signed-in session against a live
  host). See below.

## Human manual test

1. Build/run the `Superset` scheme on a Vision Pro (sim or device), sign in against a real account
   whose org has an **online, paid-plan Host** with at least one Workspace.
2. Open **Settings → Debug → Open Terminal Spike**, then switch the mode picker to **Live (relay)**.
3. Pick a Workspace (only Workspaces with a Host appear) and tap **Connect**. The status line shows
   `Connecting…` → `Attached (terminalId)`; the surface should render the host shell and echo input.
4. Type a command (e.g. `ls`, `echo hi`) and confirm output renders; resize the window and confirm
   the remote grid follows. A host-side `exit`/`error` should surface in the status line.

Requirements: a live, online host (sleeping/offline hosts throw at provisioning, surfaced as
`Failed: …`); the signed-in session's relay JWT mint must succeed (the Debug window sits outside the
Optic ID lock gate, but still mints from the live session token).
