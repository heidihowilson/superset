# PRD: Native visionOS (Apple Vision Pro) Superset App

**Status:** Reconciled after design grilling (2026-06-20) · **Owner:** visionOS app team · **Target:** `apps/visionos`

> This revision supersedes the original pressure-tested draft. Load-bearing decisions are recorded as ADRs in [`docs/adr/`](./adr/); domain language is in [`../CONTEXT.md`](../CONTEXT.md). Where this doc and the ADRs disagree, the ADRs win.

---

## 1. Summary

Build **Superset for Apple Vision Pro** — a **native SwiftUI/RealityKit** app that is a control surface for **watching and directing coding agents** across remote Workspaces. The headset is a second screen for directing and observing agents; all code execution stays on remote Hosts.

V1 ships a **flat multi-window** experience in the Shared Space — a Window per Workspace and per Project — over a **presentation-agnostic core**, so the same domain state can later render as spatial volumes (V2) by swapping renderers, not rewriting the app. The reason to go native: visionOS gives real OS-level multi-window (`WindowGroup(for:)`) the single-window Electron desktop structurally lacks, and a clean path to a spatial future.

The core loop is **watch + prompt**: follow agent chat (thinking, tool calls, results) and send prompts by **voice dictation** (reviewable composer, explicit send) or virtual keyboard. We deliberately do **not** reuse the existing web workspace UI (it is an unusable PoC — ADR-0003), do **not** embed web content (native UI — ADR-0003), authenticate via the proven **cookie session** rather than a native OAuth/PKCE bearer chain (ADR-0002), and **defer Electric** in favor of polling + the chat stream for V1 (ADR-0004).

---

## 2. Background & Problem

Superset orchestrates coding agents across Hosts. Domain model: `Organization → Project (GitHub-linked repo) → Workspace (git worktree on a Host)`; Chat sessions and terminals are scoped to Workspaces.

- **The desktop app is single-window.** `apps/desktop` (Electron 40 + React 19) creates exactly one `BrowserWindow` (`src/main/windows/main.ts`); deep links always route to `windows[0]`; layout persists globally in `app-state.json`. No window-to-workspace binding. Multi-window is unsupported — and is genuinely net-new value on visionOS.
- **The existing web workspace UI is not reusable.** `app.superset.sh/workspaces` is a borderline-unusable proof of concept; we will not wrap or fix it for visionOS (ADR-0003). Its *plumbing*, however, is sound and serves as a reference implementation (below).
- **Execution is Host-bound.** Agents run on the Host (`packages/host-service/src/trpc/router/agents/agents.ts`, `runtime/chat/chat.ts`). Host-native packages (`pty-daemon`, `host-service`, `workspace-fs`, `port-scanner`, `macos-process-metrics`) cannot run in the visionOS sandbox.
- **The Host is reached only over a reverse tunnel.** The relay (`apps/relay`) is **host-dialed** and forwards only while the Host holds a live WebSocket and passes `checkHostAccess` (allowed && paid plan). For a roaming headset, the Host being asleep/off-network is a *common* runtime state, not an edge case (R1).
- **Chat is cloud-durable.** Agent output is published to a **Durable Stream**; the API exposes it as an SSE proxy (`apps/api/src/app/api/chat/[sessionId]/stream/route.ts`, `chat/lib.ts`). So *watching* chat is cloud-served and survives a sleeping Host; *driving* the agent is not.

**The opportunity:** native OS multi-window + a presentation-agnostic core that makes today's flat windows and tomorrow's spatial volumes the same state under different renderers — delivered as a focused watch+direct surface that is honest about what needs a live Host.

---

## 3. Goals / Non-Goals

### Goals (V1)
- **G1 — Native app.** SwiftUI/RealityKit app at `apps/visionos`. No Electron, no Node/Bun runtime, no host-native packages on device (ADR-0003).
- **G2 — Watch loop.** Follow a Workspace's agent Chat session live (streamed thinking/tool-calls/results + history), Host-resilient via the Durable Stream.
- **G3 — Prompt loop.** Send prompts via **voice dictation → reviewable composer → explicit send**, virtual keyboard as fallback. Host-gated (the agent runs on the Host).
- **G4 — Multi-window capability.** Window-per-Workspace and Window-per-Project as distinct `WindowGroup(for:)` scenes keyed on domain id (system de-dupe → open-or-focus). Single-window-plus-switcher is the **default** model; multi-window is opt-in (§10).
- **G5 — Workspace lifecycle.** Create / delete / rename from the headset. Rename is cloud-only; create/delete are **Host-gated** (worktree provisioning/teardown run on the Host, client-driven relay calls mirroring the web app — §11).
- **G6 — Presentation-agnostic core.** A native domain/state layer with a renderer abstraction (pane kind → SwiftUI view in V1; → RealityKit entity in V2), so V2 spatial is a renderer swap, not a rewrite. This is the original "UI takes many forms" bet, realized natively.
- **G7 — Auth.** Web-primary **cookie session** held natively; mint short-lived JWT from `/api/auth/token` for any JWT-gated calls (Electric/relay) — mirroring the web app (ADR-0002).
- **G8 — Register as device type `visionos`** (`v2ClientTypeValues`, and `deviceTypeValues` defensively — `packages/db/src/schema/enums.ts`).

### Non-Goals (V1)
- **NG1 — No web-hosted UI / WKWebView content panes** (except the auth login webview). Native UI only (ADR-0003).
- **NG2 — No native Electric/TanStack-DB client.** V1 uses polling + the chat stream (ADR-0004); Electric is a V2 upgrade.
- **NG3 — No terminal.** Deferred to V1.1 (registered placeholder).
- **NG4 — No code-review panes** (diff/file/comment). Deferred to V1.1 (registered placeholder).
- **NG5 — No spatial scenes.** Shared Space, flat windows only. No Volume, no ImmersiveSpace in V1. App-controlled spatial arrangement is the V2 payoff.
- **NG6 — No on-device execution**, subprocesses, local git/filesystem, or host-native features (port-scanner, host-metrics, auto-updater, dock/tray).
- **NG7 — No new presentation columns on domain tables.** Window/scene/layout binding is device-local presentation state.

---

## 4. Target Users & Use Cases

**Primary (V1):** internal team + closed beta of power users who already run a Host. The headset is a **second screen for directing and watching agents**, not a primary IDE.

**Use cases:**
1. **Watch agents work** — open a Workspace window, follow agent chat at a comfortable reading distance. Host-resilient (chat is cloud-durable).
2. **Direct agents** — send prompts/instructions by voice; light navigation. Host-gated (needs a live Host).
3. **Manage parallel work** — open several Workspace windows, arrange them in space (the user arranges; the app cannot — PI-1), glance between them, switch focus by gaze.
4. **Set up / tear down** — create/delete Workspaces (Host-gated); heavy editing stays on the Mac.

**Host-reachability reality (R1, primary product constraint):** for the roaming-headset persona, the Host is frequently asleep/off-network. We distinguish two first-class states: **no Host in org** (anti-persona; directing unavailable) and **Host exists but not currently dialed in** (the common case; watch still works, directing/create are disabled with a clear host-online indicator). See §11 and the host-resilience map (§6.3).

---

## 5. Product Principles

1. **The headset is a control surface, not the engine.** Execution is remote; the device renders and directs.
2. **Domain state is presentation-agnostic.** Features bind to an observable store, never to a window or volume identity (G6).
3. **Windows are views, not owners.** A Window is a `(sceneKind, domainId)` binding; closing it never kills remote work.
4. **Be honest about the Host.** Watch works offline-of-Host; directing/create/review need a live Host and say so. Never spinners or blanks where "Host asleep" is the truth.
5. **Platform-native, not desktop-cloned.** Chrome lives in ornaments; window arrangement is left to the system and the user; voice is a first-class input.
6. **Make the spatial future cheap.** Keep the renderer seam clean so V2 volumes are a renderer swap.

---

## 6. Architecture

### 6.1 Native, not hybrid (ADR-0003)
The existing web workspace UI is unusable, so the UI is greenfield regardless — and we build it **native SwiftUI/RealityKit** for headset comfort (gaze/pinch, glass), performance, and a clean spatial path. We do not embed web content or fix the web app for visionOS. The web app's *plumbing* is a reference implementation the native client mirrors (§6.4).

### 6.2 Presentation-agnostic core + renderer seam (G6)
The "same state, many UI forms" requirement is realized within native:
- **Domain/state layer** — an observable store fed by cookie-authed tRPC queries (polling) and the chat Durable Stream (ADR-0004). No React, no Electron, no Electric in V1.
- **Renderer registry** — maps `pane kind → platform view`: SwiftUI views in V1 (2D windows), RealityKit entities in V2 (volumes). UI observes the store and emits intents; it never owns domain state.
- **Scene layer** — `WindowGroup(for:)` (V1, 2D) today; volumetric `WindowGroup` (V2) and `ImmersiveSpace` (V3) later, over the *same* store. **The boundary is swap-only; per-kind renderers are re-implemented per scene family** (a SwiftUI view is not a RealityKit entity). Going spatial changes renderers + scene type, not domain state.

### 6.3 Host-resilience map (the core honesty of the product)
| Capability | Path | Host needed? |
|---|---|---|
| Watch chat (live + history) | Durable Stream (cloud) + tRPC query | **No** — Host-resilient |
| Workspace/Project list & status | cookie tRPC query (polled) | No (cloud row) |
| Send prompt / start run | agent runs on Host via relay | **Yes** |
| Create / delete Workspace | host-service over relay | **Yes** |
| Rename / restore | cloud-only mutation | No |
| Terminal *(V1.1)*, review *(V1.1)* | host-service over relay | **Yes** |

When the Host is not dialed in: watch + browse work; prompt/create/delete are disabled behind a live **host-online indicator** with explicit "Host asleep" affordances. No offline queuing of prompts.

### 6.4 Reuse: plumbing, not UI
The web app proves the client→Host protocol the native app mirrors (reimplementation, not invention):
- `apps/web/src/trpc/host-client.ts` — browser → relay → host-service tRPC shape (`${relayUrl}/hosts/${routingKey}/trpc/${procedure}`), keyed by `machineId`.
- `apps/web/src/trpc/auth-token.ts` — mint the relay/Electric JWT from the session via `/api/auth/token`.
- `WebTerminal` transport (relay WebSocket) — reference for the V1.1 native terminal.

---

## 7. V1 Scope — The Multi-Window Experience

### 7.1 Windowing
- **PI-1 (platform invariant):** in Shared Space, window **position/orientation/arrangement are owned by the system and the user.** The app may pass a `defaultSize` hint only; it cannot place, gather, or re-arrange windows, or query "where is this window." "Spatial organization" in V1 = the *user* arranging windows.
- Window-per-Project and Window-per-Workspace are `WindowGroup(for:)` scenes keyed by domain id (`projectId`/`workspaceId`). Value de-dupe means open-or-focus is **free and system-provided** → one window per Workspace in V1 (per-instance multi-window deferred to V2).
- A **command-center / switcher** is a primary `WindowGroup`; the leading ornament hosts navigation. Deep links (`superset://`) resolve to `(sceneKind, domainId)`, fixing the desktop's `windows[0]` limitation.
- **Host-session lifecycle is decoupled from window lifecycle** — closing a window never kills Host agents/PTYs.

### 7.2 V1 surfaces
- **Project/Workspace browser + switcher** — list grouped by Project, filter/search, polled status (running/done/error, branch, unread). Source: cookie tRPC `v2Workspace.list`.
- **Watch** — Chat session view at **full desktop fidelity**: message narrative, live streaming tokens, **expandable thinking**, and **tool calls with inline results** (agent-produced diffs, command output, file reads) + history and attachments. Rendered from the chat Durable Stream / history payload (Host-resilient). Where a tool result's full content isn't in the payload and needs a Host fetch, that detail is Host-gated (degrades per §6.3). This is the agent's *own* activity inline — distinct from the user-initiated **review panes** (browsing arbitrary files / the branch git diff / PR comment threads), which remain deferred to V1.1 (NG4). This is the **largest native surface in V1** (diff/output/syntax rendering).
- **Prompt** — composer with **voice dictation** (Speech framework, on-device) → review/edit → explicit send; agent + model picker; session switcher. Host-gated.
- **Workspace lifecycle** — create/delete (Host-gated, client-driven relay), rename/restore (cloud-only).
- **Auth & org** — cookie sign-in via login webview, org list + switch, sign-out.
- **Settings (read-mostly)** — *editable:* org/team switch, model prefs, device-local appearance + dictation/notification prefs, sign-out. *Read-only views:* hosts (with live host-online indicator), projects, billing, account. *Cut/N-A on device:* terminal, git, permissions, api-keys, presets/agents/behavior (host-side), integrations, links, ringtones, experimental; keyboard reduces to a shortcut reference (§16.4).
- **Notifications** — agent lifecycle routed to the owning Workspace window if open, else the command-center ornament.
- **Onboarding (FR-ONB)** — lightweight, skippable, settings-replayable **4-beat** first-run: gaze+pinch, switcher/palette location (Cmd+K), opening your first Workspace, and window-vs-pane close (Cmd+W). See §16.3.

---

## 8. Feature Matrix (V1)

| Feature | V1 | Notes |
|---|---|---|
| Project/Workspace browser + switcher | **Must** | Polled tRPC; cache last result for instant paint. |
| Watch Chat (stream + history) | **Must** | Durable Stream; Host-resilient. **Full-fidelity transcript** incl. inline tool results (agent diffs/output) — the largest native build in V1. |
| Send prompt (voice/keyboard) | **Must** | Host-gated; dictation → composer → send. |
| Workspace create / delete | **Must (Host-gated)** | Client-driven relay calls (mirror web), keyed by `machineId`. |
| Workspace rename / restore | **Must** | Cloud-only; safe offline. |
| Multi-window capability | **Must** | Domain-id-keyed; single-window-plus-switcher default (§10). |
| Live-ish status & notifications | **Must** | Polled + lifecycle toasts; focus-routed. |
| Auth + org switch | **Must** | Cookie session (ADR-0002). |
| Settings (read-mostly) | **Must** | Incl. host-online indicator. |
| Onboarding | **Must** | FR-ONB. |
| Terminal | **Defer → V1.1** | Native PTY-over-relay-WS + backgrounding reconnect; placeholder. |
| Diff / file / comment review | **Defer → V1.1** | Host-gated native UI; placeholder. |
| Spatial volumes / immersive | **Defer → V2/V3** | Renderer swap over the same store. |
| Native Electric live-sync | **Defer → V2** | ADR-0004. |
| Browser panes, host metrics, port-scanner, auto-updater/dock/tray | **Cut** | Host/Electron-native; meaningless on device. |

Deferred/cut pane kinds stay **registered placeholders** so a synced layout from other clients stays valid; the registry is pluggable so they add later with no domain change.

---

## 9. visionOS UX & Interaction

- **Not a desktop clone.** Chrome lives in **ornaments** (leading = switcher/palette; bottom = primary actions), persistently visible — not hover-gated. No top tab strips / inline toolbars in content.
- **Input.** Primary interactions are look-and-pinch with hands resting. **Voice dictation is the primary text input**; the system virtual keyboard is the fallback. Explicit send (never send-on-pause) to avoid mis-firing prompts at autonomous agents.
- **Targets & feedback.** All interactive targets ≥60pt; every element shows a gaze/hover highlight; explicit `buttonBorderShape`.
- **Windows.** System places windows in the forward field of view; the user repositions; the app does not (PI-1). Window proliferation mitigated by system open-or-focus + an explicit "close other windows / consolidate" action.
- **Keyboard.** Cmd+W closes the focused window; pane-close is a separate in-content affordance (taught in onboarding). Cmd+K opens the palette.
- **Comfort.** The watch loop is a long, low-activity read — Vision Pro's weakest wear profile. Favor glanceable/ambient surfaces; instrument median comfortable session length; honor Reduce Motion / Bold Text / Increase Contrast.
- **Accessibility.** Every element reachable via VoiceOver / head pointer / Switch Control, not solely eye+pinch.

---

## 10. Experimentation Framework

The HMI is new, so layout/interaction models are swappable cheaply — an **internal design-iteration tool, not a powered A/B test** (dogfood N can't declare statistical winners).

- An **Interaction Model Registry** holds registered, feature-flagged models; switching re-renders the *same* store under a new model at runtime, per-device, no rebuild.
- **V1 default is `single-window-plus-switcher`** (conservative); `multi-window` is the opt-in contender. Cohort assignment is explicit opt-in / org-role only.
- **Cost-of-experiment:** adding a model = a new adapter registration + flag + config; **no domain/core change, no migration.**
- **Learning:** qualitative + behavioral (comfort logs, observed task completion, preference) + a collapse-to-single-window tripwire. Quantitative events are descriptive, not powered. Powered A/B is deferred to a population-gated later phase.

---

## 11. Auth, API & Data

### Auth (ADR-0002)
- Sign in by running the **web login flow in a webview**; hold the better-auth **session cookie** natively (`URLSession` `HTTPCookieStorage` ↔ WKWebView `WKHTTPCookieStore`).
- **tRPC + chat stream use the cookie** — `apps/api/src/trpc/context.ts` tries `getSession` before bearer; the chat route's `requireAuth` is cookie/session based.
- For any JWT-gated call (Electric in V2, relay/host-service), **mint a short-lived JWT from `/api/auth/token`** (the same token the web app uses; already carries `organizationIds`).
- **Dissolved by this choice:** the four-verifier bearer audit, custom-scheme PKCE spike, `TRUSTED_API_CLIENTS` edits, refresh-token rotation. Session **revocation** (lost/shared headset) is supported by better-auth session management. Native OAuth/PKCE is shelved for V2 only if a cookieless path is ever needed.

### API & host calls
- Cloud reads/writes: **HTTP tRPC to `apps/api`** with the cookie + org header.
- Host operations (create/delete now; terminal/review in V1.1): **relay → host-service**, client-driven, keyed by `machineId`, authed with the minted JWT — mirroring `host-client.ts`. Host-gated (`checkHostAccess`: allowed && paid).

### Data (ADR-0004)
- **No Electric in V1.** Live agent output comes from the **chat Durable Stream** (SSE). Lists/status come from **polled cookie tRPC queries**. Writes are **non-optimistic** (show pending state).
- **Cache last results** for instant paint on window open; refresh on focus/interval.
- Persistence: **session cookie** in protected storage; **UserDefaults** for device-local presentation state (window/pane layout). No SQLite/Drizzle/OPFS replica.

---

## 12. Architecture & Monorepo Placement

- **`apps/visionos`** — native SwiftUI/RealityKit. MUST NOT depend on Electron or host-native packages.
- **No new `packages/superset-core` for V1** (it existed to feed a native sync client; ADR-0004 removes that need). Revisit in V2 with native Electric.
- **Wire contract.** V1's native data needs are small (tRPC query/mutation shapes + chat stream + relay host-service calls). A lightweight TS→Swift type-generation step for the in-scope procedures is *nice-to-have*, not a gate; hand-typed request/response models are acceptable for the V1 surface and can be codegen'd later.
- **Schema:** add `'visionos'` to `v2ClientTypeValues` (required) and `deviceTypeValues` (defensive) in `packages/db/src/schema/enums.ts`; additive migration via `drizzle-kit generate` (maintainer-run; never hand-edit `packages/db/drizzle/`).
- **Registry:** chat at parity in V1; diff/file/comment/terminal/browser as registered placeholders.

---

## 13. Non-Functional Requirements

- **Performance:** no sync I/O on the main thread; multi-window scenes share one in-process store; bound memory for large orgs (lazy/per-workspace queries).
- **Streams & backgrounding:** the chat SSE must reconnect/resume across visionOS backgrounding without blanking shown data (this is the key reliability risk for the watch loop — R3).
- **Comfort & spatial:** launch into Shared Space; world-anchored windows; system glass materials; ambient-first for long reads.
- **Accessibility:** full VoiceOver / head-pointer / Switch-Control coverage; Reduce Motion / Bold Text / Increase Contrast honored.
- **Security & privacy:** gaze for system targeting only (never inferred/logged); client only sees data for orgs in its session; outbound HTTPS/WSS only, no inbound listeners; session-cookie revocation as the lost-device control.

---

## 14. Phased Roadmap

- **V1 — Native flat multi-window watch+direct.** App shell + windowing; watch + prompt (voice); workspace lifecycle (Host-gated create/delete, cloud rename); cookie auth; polling + chat stream; browser/switcher; settings; onboarding; register `visionos`. Default single-window-plus-switcher with multi-window opt-in.
- **V1.1 — Host-gated power features.** Native terminal (PTY-over-relay-WS + backgrounding reconnect; design spike first) and code-review panes (diff/file/comment).
- **V2 — Spatial.** Volume-per-Workspace (`windowStyle(.volumetric)`): app-controlled arrangement of Workspace surfaces; RealityKit renderer set per pane kind (the renderer-swap payoff). **Native Electric/TanStack-DB** for live queries/optimistic writes/offline.
- **V3 — Immersive command deck (optional).** `ImmersiveSpace` for power users, with an in-app exit.
- **Later (population-gated):** powered interaction-model A/B.

---

## 15. Risks & Mitigations

| # | Risk | Mitigation |
|---|---|---|
| **R1 (TOP)** | **Host unreachable is the default state for a roaming headset** → prompt/create/delete (and V1.1 terminal/review) are frequently unavailable. | Watch is the Host-resilient core (Durable Stream); host-resilience map (§6.3); first-class "Host asleep" affordances + live host-online indicator; no offline prompt queuing. |
| R2 | **Web UI is unusable; native UI is greenfield** → V1 build cost is real. | Scope kept tight (watch+chat+lifecycle); review/terminal/spatial deferred; native renderer seam reused across V1.1/V2. |
| R3 | **Chat SSE reconnect/replay across visionOS backgrounding** is the watch loop's reliability crux. | Resume-from-offset on the Durable Stream; cache + reconcile; never blank shown data; validate on hardware early. |
| R4 | **Create/delete re-incur Host-dependent provisioning** (R-CREATE). | Client-driven relay calls mirroring the web app, keyed by `machineId`; Host-gated UI; cloud row + host saga; never queued. |
| R5 | **Polling staleness / non-optimistic writes** feel laggy. | Acceptable at dogfood scale; pending-state UI; Electric upgrade is the V2 answer (ADR-0004). |
| R6 | **Cookie sharing (`URLSession` ↔ WKWebView) + session lifetime.** | Single source of truth for the cookie store; refresh/re-auth on 401 before any sign-in UI; session revocation for lost devices. |
| R7 | **Presentation/domain boundary leaks** (window/layout creeps into domain schema), breaking the spatial path. | NG7; device-local presentation state; renderer seam discipline; code review. |
| R8 | **Spatial value is deferred to V2** → V1 may feel like "desktop windows in a headset." | V1 is explicitly a foundation + ergonomics-learning release; honest framing; the renderer seam makes V2 the payoff, not a rewrite. |

**Dissolved vs the original draft:** native bearer four-verifier audit, PKCE custom-scheme spike, refresh-rotation blocker (→ cookie auth, ADR-0002); native Swift Electric client + M0-Sync hardware gate (→ polling, ADR-0004); hybrid spatial-debt risk (→ native, ADR-0003).

---

## 16. Resolved Design Details

All open questions from the design grilling are resolved:

1. **Watch UI content** — full desktop-fidelity transcript (inline tool results, expandable thinking) from the stream payload; user-initiated review browsing stays V1.1 (§7.2). Inline-result renderers: markdown/text, collapsible thinking, and tool-result views for **file edit/diff, shell output, file read, search results, web fetch**, plus a **generic fallback** for unknown tool types. Render from the stream payload; truncated results show an inline summary + an "open full" that fetches from the Host (Host-gated; summary-only when the Host is asleep). Never block the transcript on a Host fetch.
2. **Deep-links & scene restoration** — reuse the `superset://` scheme (existing: `setAsDefaultProtocolClient`/`parseAuthDeepLink`) with grammar `superset://workspace/<id>`, `superset://project/<id>`, `superset://session/<chatSessionId>`; a router maps path → `(sceneKind, domainId)` and value-keyed scenes give open-or-focus for free. Enable scene `restorationBehavior` for project/workspace windows (restore by domain id), off for transient utility windows; device-local presentation state records open windows + per-window UI. Notifications carry `(sceneKind, domainId)` and focus-or-open on tap.
3. **Onboarding (FR-ONB)** — a lightweight, skippable, settings-replayable **4-beat** first-run: (1) gaze+pinch, (2) switcher/palette location (Cmd+K), (3) open your first Workspace, (4) window-close vs pane-close (Cmd+W). Acceptance: a first-run user reaches "first Workspace open" without prior knowledge of ornament locations.
4. **Settings scope** — **minimal editable set**: org/team switch, model prefs, device-local appearance + dictation/notification prefs, sign-out. **Read-only views**: hosts (+ live online indicator), projects, billing, account. **Cut/N-A on device**: terminal, git, keyboard (→ shortcut reference only), permissions, api-keys, presets/agents/behavior (host-side), integrations, links, ringtones, experimental.
5. **V1→V2 boundary** — **minimum-viable seam** (clean store↔UI separation + simple registry + throwaway second adapter for M0); no speculative RealityKit/volume abstraction until V1 learnings inform V2.
6. **Status liveness** — **open** Workspaces get live status from their own chat stream; the browser/switcher list **polls** `v2Workspace.list` (~5–10s while visible, paused when hidden) with last-result caching. No cloud status-push exists short of Electric (only the chat SSE is client-facing); a status push is a V2 item. (Confirms ADR-0004.)

---

## 17. Success Metrics

**Acceptance (V1 ship gates):**
- **M0 — Renderer seam (minimum-viable):** the same unmodified store drives the production 2D window adapter and a second registered (throwaway) adapter, proving the boundary holds with zero domain change. Built to the minimum that proves separation — no speculative spatial abstraction. (Hard gate for G6; Shared Space only.)
- **M0b — Cost-of-experiment:** a second interaction model is adapter+flag+config only — no domain/core change, no migration.
- **M0c — Watch on hardware:** open a Workspace, stream live agent output, and **resume the chat SSE across a backgrounding cycle without blanking** shown data. (Hard gate — R3.)
- **M0d — Direct on hardware:** voice-dictate a prompt, review, send, and see the agent run (Host online). Auth via cookie session; org switch without re-auth.
- **M0e — Lifecycle:** create and delete a Workspace from the headset against a live Host; rename offline-of-Host.

**Product (dogfood — qualitative + behavioral):**
- **M1** — time-to-first-meaningful-view (sign-in → first Workspace surface) under target; onboarding effectiveness.
- **M2** — comfort/fatigue logs + observed task completion on the watch/direct loops + preference (descriptive, not powered).
- **M3** — multi-window engagement-with-value (≥2 windows each receiving meaningful gaze dwell) **excluding** structurally-forced pairs; collapse-to-single-window tripwire as the falsifier.
- **M4** — median comfortable session length per device/model.

**Host-reachability assumption (must be quantified):**
- **M-Host** — % of headset sessions with a live Host tunnel. If low, lean harder on the watch loop and reconsider a cloud-cached read path before investing in V1.1 review.

---

## Decision log

- **ADR-0001** — Hybrid rendering (native shell + WKWebView panes) — **superseded by 0003**.
- **ADR-0002** — Web-primary cookie-session auth — **accepted**.
- **ADR-0003** — Native SwiftUI workspace UI — **accepted** (supersedes 0001).
- **ADR-0004** — V1 polling + chat stream, not Electric — **accepted**.
