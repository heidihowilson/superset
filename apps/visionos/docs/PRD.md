# PRD: Native visionOS (Apple Vision Pro) Superset App

**Status:** Reconciled after adversarial code-review (2026-06-20) · **Owner:** visionOS app team · **Target:** `apps/visionos`

> This revision applies the adversarial review that invalidated two earlier assumptions (cookie-from-webview auth; host-resilient watch). Load-bearing decisions are ADRs in [`docs/adr/`](./adr/); domain language is in [`../CONTEXT.md`](../CONTEXT.md). Where this doc and the ADRs disagree, the ADRs win.

---

## 1. Summary

Build **Superset for Apple Vision Pro** — a **native SwiftUI/RealityKit** app that is a spatial control surface for **watching and directing coding agents** on a remote Host. The headset is worn while your **Host is awake** (at your desk, or a remote Host kept running); all execution stays on the Host.

V1 ships a **flat multi-window** experience in the Shared Space — a Window per Workspace and per Project — over a **presentation-agnostic core**, so the same domain state can later render as spatial volumes (V2) by swapping renderers, not rewriting the app. The reason to go native: visionOS gives real OS-level multi-window (`WindowGroup(for:)`) the single-window Electron desktop lacks, and a clean path to a spatial future.

The core loop is **watch + prompt**, and — per the adversarial review — **both are Host-gated**: chat lives on the Host (Electron IPC / Mastra memory; the cloud Durable Stream is unwired), and the agent runs on the Host. The only Host-independent surface is the cloud Workspace/Project list. V1 therefore assumes a **reachable, awake Host** (ADR-0006); it is not a roaming, host-asleep companion.

Decisions that shape the build: **native UI**, not web panes (ADR-0003); **bearer-token auth via a system-browser handoff** (ADR-0005 — cookie-from-webview is impossible because Google blocks OAuth in embedded WKWebViews); **no Electric** in V1 — host-service-over-relay reads + polling (ADR-0004); **host-awake, watch host-gated** (ADR-0006); **on-device observability** from day one (ADR-0007).

---

## 2. Background & Problem

Superset orchestrates coding agents across Hosts. Domain model: `Organization → Project (GitHub-linked repo) → Workspace (git worktree on a Host)`; Chat sessions and terminals are scoped to Workspaces.

- **The desktop app is single-window** (`apps/desktop/src/main/windows/main.ts`); deep links route to `windows[0]`; layout is global in `app-state.json`. Multi-window is genuinely net-new value on visionOS.
- **The existing web workspace UI is unusable** (`app.superset.sh/workspaces` is a PoC); we will not wrap or fix it (ADR-0003). Its *plumbing* is a reference implementation.
- **Chat is Host-bound, not cloud-durable.** A cloud Durable Stream SSE proxy exists (`apps/api/src/app/api/chat/[sessionId]/stream/route.ts`) but **nothing publishes to it** (`appendToStream`/`ensureStream` in `chat/lib.ts` have zero callers). Live chat flows over **Electron IPC** from an in-memory Host runtime (`packages/chat/src/server/trpc/service.ts`); history lives in the **Host's Mastra memory** (no `chat_messages` table; `chat_sessions` stores metadata only). So watching is Host-gated.
- **Execution is Host-bound.** Agents run on the Host (`packages/host-service/src/trpc/router/agents/agents.ts`). Host-native packages (`pty-daemon`, `host-service`, `workspace-fs`, …) cannot run in the visionOS sandbox.
- **The Host is reached only over a reverse tunnel.** The relay (`apps/relay`) is host-dialed and forwards only while the Host holds a live WebSocket and passes `checkHostAccess` — `allowed && paidPlan`, where `paidPlan` includes `trialing` (`packages/shared/src/billing.ts`). **Free-plan orgs are hard-blocked at tunnel registration** (`apps/relay/src/index.ts`).
- **A valid relay JWT reaches the full host-service surface** — including `terminal.createSession` running arbitrary commands — i.e. **RCE on the developer's machine**, not a read-only leak. The token is a high-value secret.

**The opportunity:** native OS multi-window + a presentation-agnostic core (flat windows now, spatial volumes later), delivered as a focused spatial control surface for a live Host.

---

## 3. Goals / Non-Goals

### Goals (V1)
- **G1 — Native app.** SwiftUI/RealityKit at `apps/visionos`. No Electron, no Node/Bun runtime, no host-native packages on device (ADR-0003).
- **G2 — Watch loop (Host-gated).** Follow a Workspace's agent Chat session — live + history — read from **host-service over the relay**. Requires a reachable Host (ADR-0006).
- **G3 — Prompt loop (Host-gated).** Send prompts via **voice dictation or virtual keyboard, as co-equal modalities** (dictation gated on an accuracy bar, §9), reviewable composer, explicit send. The agent runs on the Host.
- **G4 — Multi-window capability.** Window-per-Workspace and Window-per-Project as `WindowGroup(for:)` scenes keyed on domain id (system de-dupe → open-or-focus). Single-window-plus-switcher is the **default**; multi-window is opt-in (§10).
- **G5 — Workspace lifecycle (Host-gated).** Create / delete from the headset (worktree provisioning/teardown on the Host, client-driven relay calls mirroring the web app); rename/restore are cloud-only.
- **G6 — Presentation-agnostic core.** Native domain/state layer + a minimum-viable renderer seam (pane kind → SwiftUI view in V1; → RealityKit entity in V2), so V2 spatial is a renderer swap (§17 M0).
- **G7 — Auth.** Reuse the desktop token handoff (verified): ASWebAuthenticationSession → `/api/auth/desktop/connect` → OAuth → `superset://auth/callback?token=` (a 30-day better-auth session-table token) → Keychain → `Authorization: Bearer`; mint a JWT from `/api/auth/token` for relay/host calls (ADR-0005).
- **G8 — Device registration: NOT required for V1 (verified).** The web app registers **no** device/client and functions fully, so visionOS doesn't need to either for watch/prompt/lifecycle. **Deferred** — add a `'visionos'` device-type enum value only if/when remote-*targeting* the headset (sending it commands) becomes a feature. At that point the targeting path needs sorting (`device_presence` is v1 code marked *"retired"*; `host.ensureClient`→`v2Clients` is uncalled).

### Non-Goals (V1)
- **NG1 — No web-hosted UI / WKWebView content panes**, except (a) the auth handoff and (b) the transcript's rich-content rendering surface (markdown/syntax/diff, ADR-0009). Native UI everywhere else (ADR-0003).
- **NG2 — No native Electric/TanStack-DB client, and the cloud Durable Stream is NOT used in V1** (it's unwired). Both are V2 (ADR-0004/0006).
- **NG3 — No terminal.** Deferred to V1.1 (registered placeholder).
- **NG4 — No code-review panes** (diff/file/comment). Deferred to V1.1 (registered placeholder).
- **NG5 — No spatial scenes.** Shared Space, flat windows only. App-controlled spatial arrangement is the V2 payoff.
- **NG6 — No on-device execution / host-native features** (terminal-as-execution, port-scanner, host-metrics, auto-updater, dock/tray).
- **NG7 — No new presentation columns on domain tables.** Window/scene/layout binding is device-local presentation state.
- **NG8 — No roaming / host-asleep companion.** V1 assumes a reachable Host; host-offline shows only the Workspace list (ADR-0006). No offline prompt queuing.

---

## 4. Target Users & Use Cases

**Primary (V1):** internal team + closed beta who run a Host and wear the headset **while that Host is awake** — at the desk beside the Mac, or with a remote Host kept running. The headset is a **spatial control surface for live agents**, not a roaming companion and not a primary IDE. Each dogfood test org needs an **active/trialing subscription** or every host call 403s (§2).

**Use cases (all require a live Host):**
1. **Watch agents work** — open a Workspace window, follow agent chat (thinking/tool-calls/results) across several windows.
2. **Direct agents** — send prompts by voice or keyboard; light navigation.
3. **Manage parallel work** — open several Workspace windows, arrange them in space (the user arranges; the app cannot — PI-1), glance between them.
4. **Set up / tear down** — create/delete Workspaces.

**Host-reachability (R1):** V1 targets **remote, always-on Hosts** — Superset Pro supports remote hosts, so the headset develops against an external machine kept running, **not** the wearer's sleeping Mac. Host-awake is therefore the *natural* model, not a compromise. When a Host is unreachable, V1 shows the cloud Workspace/Project list + an explicit **"Host offline"** state distinguishing *asleep* from *plan-gated 403*. Roaming against a sleeping personal Mac is out of V1 scope (a future host-wake / cloud-durable-stream path, §14).

---

## 5. Product Principles

1. **The headset is a control surface, not the engine.** Execution is remote; the device renders and directs a live Host.
2. **Domain state is presentation-agnostic.** Features bind to an observable store, never to a window or volume identity (G6).
3. **Windows are views, not owners.** A Window is a `(sceneKind, domainId)` binding; closing it never kills remote work.
4. **Be honest about the Host.** V1 needs a live Host; host-offline is a first-class, clearly-messaged degraded state, never a spinner or blank.
5. **Platform-native, not desktop-cloned.** Chrome in ornaments; the system and user place windows; voice and keyboard are co-equal inputs.
6. **Make the spatial future cheap.** Keep the minimum-viable renderer seam clean so V2 volumes are a renderer swap.

---

## 6. Architecture

### 6.1 Native, not hybrid (ADR-0003)
The web workspace UI is unusable, so the UI is greenfield and built **native SwiftUI/RealityKit** for comfort, performance, and a clean spatial path. The web app's *plumbing* is a reference the native client mirrors (§6.4).

### 6.2 Presentation-agnostic core + minimum-viable renderer seam (G6)
- **Domain/state layer** — an observable store fed by bearer-authed tRPC (cloud list) and **host-service-over-relay** reads (chat/watch/lifecycle). No React/Electron/Electric.
- **Renderer registry** — `pane kind → platform view`: SwiftUI in V1, RealityKit in V2. UI observes the store and emits intents; it never owns domain state.
- **Scene layer** — `WindowGroup(for:)` (V1) → volumetric `WindowGroup` (V2) → `ImmersiveSpace` (V3) over the same store. Boundary swap-only; per-kind renderers re-implemented per scene family. Built to the **minimum that proves separation** (M0) — no speculative spatial abstraction.

### 6.3 Host-resilience map (V1 reality — ADR-0006)
| Capability | Path | Works when Host asleep? |
|---|---|---|
| Workspace/Project list & status | cloud tRPC (bearer), polled | **Yes** (only this) |
| Watch chat (history + near-live) | host-service `chat.getDisplayState`/`listMessages` queries over relay, polled | **No** — Host-gated |
| Send prompt / start run | agent on Host via relay | No |
| Create / delete Workspace | host-service over relay | No |
| Rename / restore | cloud-only mutation | Yes |
| Terminal *(V1.1)*, review *(V1.1)* | host-service over relay | No |

Host-offline state: the list renders; everything else shows an explicit "Host offline (asleep / plan-gated)" affordance. No offline queuing of prompts (ADR-0006).

### 6.4 Reuse: plumbing, not UI
- `apps/web/src/trpc/host-client.ts` — browser → relay → host-service shape (`${relayUrl}/hosts/${routingKey}/trpc/${procedure}`), keyed by `machineId`; **SuperJSON `{json, meta}` envelope** (Date handling) — a named small work item, not "nice-to-have codegen."
- `apps/web/src/trpc/auth-token.ts` — mint the relay JWT from the session via `/api/auth/token`.
- `apps/mobile` `@better-auth/expo` + the desktop `superset://auth/callback?token=` flow — the auth reference (ADR-0005).
- The host-service chat router + `WebTerminal` relay WebSocket — reference for live watch / the V1.1 terminal.

---

## 7. V1 Scope — The Multi-Window Experience

### 7.1 Windowing
- **PI-1:** in Shared Space, window position/orientation/arrangement are owned by the system and the user. The app may pass a `defaultSize` hint only. "Spatial organization" in V1 = the *user* arranging windows.
- Window-per-Project / -Workspace are `WindowGroup(for:)` scenes keyed by domain id → value de-dupe gives open-or-focus for free → one window per Workspace in V1 (per-instance multi-window is V2).
- A **command-center / switcher** is a primary `WindowGroup`; leading ornament hosts navigation. Deep links (`superset://`) resolve to `(sceneKind, domainId)`; the existing `superset://auth/callback` is part of the grammar (§16.2).
- **Host-session lifecycle is decoupled from window lifecycle.**

### 7.2 V1 surfaces (all content surfaces are Host-gated except the list)
- **Project/Workspace browser + switcher** — cloud tRPC `v2Workspace.list`, polled, cached for instant paint; the one Host-independent surface. Status distinguishes asleep vs plan-gated.
- **Watch** — Chat session view from **host-service `chat.getDisplayState`/`listMessages` queries over the relay** (polled; near-live — no live subscription exists yet, §11), in **two presentations over one store**: an **ambient default** (glanceable narrative + status) and a **lean-in full-fidelity** mode (expandable thinking + tool-result renderers). Inline-result renderers (bounded set): markdown/text, file edit/diff, shell output, file read, search results, web fetch, **generic fallback** for other tool types. Oversized results show a summary + an explicit "open full" host fetch (never a scroll side-effect). **Rich content (streaming markdown, syntax-highlighted code, diffs) renders in a WKWebView reusing the desktop's web stack** — `streamdown`, `shiki`, and `@pierre/diffs` (diffs.com) — behind the renderer protocol (ADR-0009), fed by native (no auth/network in the webview); native owns the shell, lists, composer, and chrome. This dissolves the native-substrate build (R6).
- **Prompt** — composer with **voice dictation and virtual keyboard as co-equal inputs** (dictation gated on a WER bar, §9; quick-action chips for approve/reject/retry), agent + model picker (model picker is cloud; **agent-preset picker is Host-gated** — empty when the Host sleeps), session switcher. Text-only in V1 (attachment upload deferred).
- **Workspace lifecycle** — create/delete (Host-gated, client-driven relay), rename/restore (cloud-only).
- **Auth & org** — system-browser sign-in (ADR-0005), org list + switch (`setActive()`), sign-out (drops the Keychain token).
- **Settings (read-mostly)** — *editable:* org/team switch, model prefs, device-local appearance + dictation/notification prefs, sign-out. *Read-only views:* hosts (with live host-online indicator), projects, billing, account. *Cut/N-A:* terminal, git, permissions, api-keys, presets/agents/behavior (host-side), integrations, links, ringtones, experimental; keyboard → shortcut reference.
- **Notifications (in-app only)** — agent lifecycle routed to the owning Workspace window if open, else the command-center ornament. **Out-of-headset alerting is explicitly out of V1 scope** — that is the desktop app's story (Superset already notifies you there). No APNs work in this client.
- **Onboarding (FR-ONB)** — lightweight, skippable, settings-replayable **5-beat** first-run: gaze+pinch, switcher/palette (Cmd+K), **host-online state (what "Host offline" means)**, open your first Workspace, window-vs-pane close (Cmd+W). No-Host orgs get a **"connect a Host" terminal state** (QR/deep-link), since "open first Workspace" is impossible without a Host.

---

## 8. Feature Matrix (V1)

| Feature | V1 | Notes |
|---|---|---|
| Project/Workspace browser + switcher | **Must** | Cloud tRPC; only Host-independent surface. |
| Watch Chat (live + history) | **Must (Host-gated)** | host-service over relay; ambient + full-fidelity; **rich content via WKWebView** (`streamdown`/`shiki`/`@pierre/diffs`, ADR-0009). |
| Send prompt (voice/keyboard) | **Must (Host-gated)** | Co-equal modalities; explicit send; agent runs on Host. |
| Workspace create / delete | **Must (Host-gated)** | Client-driven relay, keyed by `machineId`. |
| Workspace rename / restore | **Must** | Cloud-only; safe Host-offline. |
| Multi-window capability | **Must** | Domain-id-keyed; multi-window only (single-window-plus-switcher retired, V1.1/ADR-0011). |
| Status & in-app notifications | **Must** | Polled list + lifecycle toasts; host-online indicator. |
| Auth + org switch | **Must** | Bearer handoff (ADR-0005). |
| Settings (read-mostly) | **Must** | Minimal editable set. |
| Onboarding | **Must** | 5-beat incl. host-online + no-Host state. |
| Observability (crash + telemetry) | **Must** | ADR-0007. |
| Out-of-headset alerting (APNs) | **Out of scope** | Desktop app's story; not this client. |
| Terminal | **Defer → V1.1** | Native PTY-over-relay-WS + backgrounding reconnect. |
| Diff / file / comment review | **Defer → V1.1** | Host-gated native UI. |
| Host-resilient watch (cloud stream) | **Defer → V2** | Build Durable Stream producer + consumer + history. |
| Spatial volumes / immersive | **Defer → V2/V3** | Renderer swap over the same store. |
| Native Electric live-sync | **Defer → V2** | ADR-0004. |
| Browser panes, host metrics, auto-updater/dock/tray | **Cut** | Host/Electron-native. |

Deferred/cut pane kinds stay registered placeholders so synced layouts stay valid.

---

## 9. visionOS UX & Interaction

- **Not a desktop clone.** Chrome in **ornaments** (leading = switcher/palette; bottom = primary actions), persistently visible. No top tab strips / inline toolbars in content.
- **Input — co-equal modalities.** Look-and-pinch with hands resting; **voice dictation and virtual keyboard are co-equal** (not voice-primary). Dictation must pass an **M0d word-error-rate bar on real agent prompts** (paths, `--no-verify`, camelCase) before it ships as a recommended path; quick-action chips cover approve/reject/retry; evaluate Mac-keyboard handoff. Explicit send (never send-on-pause). **On-device recognition is conditional** (`supportsOnDeviceRecognition`) and silently falls back to *server* recognition — V1 must detect this and either disable dictation or disclose it (privacy, §13).
- **Two Watch presentations.** Ambient/glanceable default vs lean-in full-fidelity — resolving the §7.2-fidelity / comfort tension over one store.
- **Targets & feedback.** ≥60pt targets; gaze/hover highlight; explicit `buttonBorderShape`.
- **Windows.** System places; user repositions; app cannot (PI-1). Open-or-focus is system-provided; an explicit "close other windows / consolidate" action mitigates proliferation. Acknowledge a memory-pressure-bounded practical window ceiling.
- **Keyboard.** Cmd+W closes the focused window; pane-close is separate (taught in onboarding). Cmd+K palette.
- **Comfort.** Long low-activity reads are Vision Pro's weakest profile; the ambient default favors glanceable surfaces. Set a real M4 session-length target.
- **Accessibility.** VoiceOver / head-pointer / Switch-Control coverage; Reduce Motion / Bold Text / Increase Contrast.
- **Simulator caveat.** Gaze targeting, true backgrounding, and comfort cannot be validated in the simulator — simulator-green ≠ acceptance for those (gates are "on hardware").

---

## 10. Experimentation Framework

Internal design-iteration tool, not a powered A/B test (dogfood N can't declare winners).

> **V1.1 (ADR-0011):** the windowing experiment concluded — **multi-window is the only model**; `single-window-plus-switcher` and the runtime `InteractionModelRegistry` are retired. Opening a workspace always opens/focuses its own window; the explicit "consolidate windows" action stays as the proliferation mitigation (§9). The renderer-seam framing below (adapter + config) still holds for the future spatial-renderer swap.

- **Renderer seam:** registered presentation adapters over one store; a new presentation re-renders the same store at runtime, no rebuild.
- **Cost-of-experiment:** a new renderer = adapter + config; no domain/core change, no migration.
- **Learning:** qualitative + behavioral. Quantitative events descriptive only. Powered A/B is a population-gated later phase.

---

## 11. Auth, API & Data

### Auth (ADR-0005)
- **System-browser handoff (reuse desktop, verified):** `ASWebAuthenticationSession` → **`/api/auth/desktop/connect?provider=…&state=…&protocol=superset`** → OAuth (real Safari; Google/GitHub) → **`/auth/desktop/success`** mints a better-auth **session-table token** (30-day) and deep-links **`superset://auth/callback?token=…&expiresAt=…&state=…`** → capture via ASWebAuthenticationSession → store in **Keychain** → **`Authorization: Bearer <token>`** on every API/tRPC call (enabled `bearer()` plugin, `packages/auth/src/server.ts:778`; the desktop does exactly this). Relay/host calls: mint a JWT from `/api/auth/token`.
- **Do not** attempt cookie-from-webview (Google blocks embedded WKWebViews; ASWebAuthenticationSession returns no cookies; the session cookie is `httpOnly`). Persist the ~30d `session_token`, **not** the 5-min `session_data` cache cookie.
- **Relay/host JWT:** mint a short-lived RS256 JWT from `/api/auth/token` (authed with the session bearer); it carries `organizationIds`. Send as Bearer to the relay.
- **Active org** = the session's `activeOrganizationId` via `setActive()` (not the JWT, which is a frozen membership snapshot); `x-superset-organization-id` is an optional override header.
- **No cookie/OAuth refresh endpoint exists** — on 401, re-run the handoff. There is no silent refresh.
- **Cold start (fresh install):** launch → no token in Keychain → handoff → token → resolve any pending `superset://` deep link → land in the target scene.

### API & host calls
- Cloud reads/writes: HTTP tRPC to `apps/api`, Bearer + active-org.
- Host operations (watch/chat/create/delete now; terminal/review V1.1): **relay → host-service**, client-driven, keyed by `machineId`, authed with the minted JWT — mirroring `host-client.ts`. Host-gated (`checkHostAccess`: `allowed && paidPlan(incl. trialing)`).
- **SuperJSON** `{json, meta}` (de)serialization on tRPC and host calls (Date handling) — a named work item for hand-typed Swift models.

### Data (ADR-0004 / ADR-0006)
- **No Electric, no cloud Durable Stream in V1.** Workspace/Project list from polled cloud tRPC (~5–10s while visible, paused when hidden), cached for instant paint. **Watch reads chat from host-service `chat.getDisplayState` / `chat.listMessages` queries over the relay, polled** — these queries exist; there is **no live chat *subscription*** exposed today (live tokens flow only over the desktop's local IPC). Near-live via polling; true token streaming (a host-service chat `.subscription()` + relay forwarding) is deferred to V2 (§14). All Host-gated.
- Writes are non-optimistic (pending state).
- Persistence: **Keychain** (session token — a high-value secret, §13); **UserDefaults** for device-local presentation state. No SQLite/Drizzle replica.

---

## 12. Architecture & Monorepo Placement

- **`apps/visionos`** — native SwiftUI/RealityKit. No Electron / host-native deps.
- **No new `packages/superset-core` for V1** (ADR-0004 removed the native-sync need). Revisit in V2 with native Electric.
- **Schema: no enum change needed for V1** — device registration is deferred (G8; the web app registers nothing and works). If remote-targeting-the-headset is later added, append `'visionos'` **last** to the relevant enum (else Drizzle emits a destructive recreate) and resolve the targeting path then (`device_presence` v1 'retired' vs uncalled `v2Clients`). Additive migration via `drizzle-kit generate` (maintainer-run; never hand-edit `packages/db/drizzle/`).
- **Wire contract:** hand-typed Swift models for the small V1 surface (cloud tRPC + host-service calls), with **SuperJSON `{json, meta}` handling** (§11). A TS→Swift codegen step is a later nicety; account for server-contract drift (§15) since there is no auto-updater.
- **Rich-content rendering = web stack in a WKWebView (ADR-0009):** the transcript's markdown/syntax/diff renders via the desktop's libraries — `streamdown` (streaming markdown), `shiki` (syntax), `@pierre/diffs` (diffs) — inside a webview behind the renderer protocol, fed by native (no auth/network in the webview). No native Swift substrate to build; tune the webview for the headset (≥60pt, gaze scroll, glass theming) and bridge interactions to native.
- **Registry:** chat at parity in V1; diff/file/comment/terminal/browser as registered placeholders.

---

## 13. Non-Functional Requirements

**Security (elevated — the relay JWT is an RCE key).**
- A valid relay JWT reaches the **full host-service surface** (e.g. `terminal.createSession` runs arbitrary commands) = **RCE on the developer's Host**. The Keychain token + the minted JWT are high-value secrets: short JWT TTL, drop tokens on sign-out/background where feasible, never log them.
- **Revocation lags ~1h:** relay/host JWTs are stateless (JWKS verify, no revocation lookup) + a 15-min `allowedCache`. Session revocation does **not** immediately cut host access. Treat as a known limitation; prefer low TTL + proactive token drop.
- **Optic ID gate, per-user device (ADR-0008):** gate app access + the stored credential behind **Optic ID** (LocalAuthentication) on launch/foreground — "put it on, see your workspaces." Clear the cached relay JWT on background; re-auth on foreground (also mitigates the ~1h revocation lag). Platform constraint: Optic ID is the enrolled owner; shared-headset auto-switch-by-face is not native — each user has their own device + login.
- Gaze for system targeting only — **never inferred or logged**. Outbound HTTPS/WSS only; no inbound listeners. Client sees only orgs in its membership.

**Performance.**
- No sync I/O on the main thread; multi-window scenes share one in-process store.
- **View-side memory:** N windows each holding full-fidelity transcripts (diffs/syntax) is the real cost — virtualize scrollback and release rendered content for backgrounded windows. Acknowledge the practical window ceiling.

**Reliability / streams.**
- Host-service stream consumption must reconnect/resume across visionOS backgrounding without blanking shown data. Specify the host-service-stream contract (resume, aged-out → refetch, connection limits vs multi-window fan-out); validate on hardware (M0c). This is net-new with no reference client.

**Comfort & spatial / Accessibility / Observability.** As §9; launch into Shared Space; world-anchored windows; system glass. Crash + telemetry per ADR-0007 (never log gaze).

---

## 14. Phased Roadmap

- **V1 — Native flat multi-window, host-awake.** Shell + windowing; watch (Host-gated, ambient + full-fidelity) + prompt (voice/keyboard); lifecycle (Host-gated create/delete, cloud rename); bearer-handoff auth; cloud list polling + host-service-over-relay reads; settings; 5-beat onboarding; observability; register `visionos`. Single-window-plus-switcher default.
- **V1.1 — Host-gated power features.** Native terminal (PTY-over-relay-WS + backgrounding reconnect; spike first) and review panes (diff/file/comment).
- **V2 — Resilience + spatial.** **True live chat streaming** (host-service chat `.subscription()` + relay subscription forwarding, replacing V1 polling). Optionally the **Durable Stream producer + native consumer + cloud chat history** for host-resilient watch. **Native Electric** for live queries/optimistic writes/offline. **Volume-per-Workspace** (`windowStyle(.volumetric)`) with a RealityKit renderer set. (**Cloud-mediated host-wake is deprioritized** — remote always-on Hosts make a sleeping Host rare; revisit only if personal-Mac roaming becomes a goal.)
- **V3 — Immersive command deck (optional).** `ImmersiveSpace`, in-app exit.
- **Later (population-gated):** powered interaction-model A/B; APNs server-push.

---

## 15. Risks & Mitigations

| # | Risk | Mitigation |
|---|---|---|
| R1 | **V1 needs a live Host; host-offline yields only the Workspace list** (ADR-0006). | **Mitigated by targeting remote always-on Hosts** (§4) — host-awake is the norm; explicit "Host offline (asleep / plan-gated)" state; roaming against a sleeping personal Mac + host-resilient watch are V2 (Durable Stream producer/consumer, host-wake). |
| R2 | Auth handoff. | **Low risk — reuse the desktop flow verbatim** (verified: `/api/auth/desktop/connect` → `superset://auth/callback?token=` → Bearer). Register the `superset://` scheme + ASWebAuthenticationSession capture; M0a gate on hardware. |
| R3 | **RCE surface:** a leaked token = full host-service command execution. | Short JWT TTL, drop on sign-out/background, never log; treat Keychain token as top secret (§13). |
| R4 | **Revocation lags ~1h** (stateless JWT). | Low TTL + proactive token drop; document non-immediacy; lost-device flow (§13). |
| R5 | **Free-plan orgs 403 on every host call.** | Each dogfood org carries an `active`/`trialing` sub; host-online indicator distinguishes asleep vs plan-gated. |
| R6 | ~~Full-fidelity transcript has no Swift substrate~~ **Resolved (ADR-0009):** rich content renders in a WKWebView reusing `streamdown`/`shiki`/`@pierre/diffs`. Residual: tune the webview for headset comfort + bridge interactions to native. |
| R6b | **No live chat *subscription* over the relay** — host-service exposes chat history/state as **queries** (`getDisplayState`/`listMessages`, relay-consumable ✓) but live tokens flow only over the desktop's local IPC. | V1 **polls `getDisplayState` over the relay** for near-live watch (no new infra; fits ADR-0004). True streaming (host-service chat `.subscription()` — infra exists, see `ports.ts` — + relay subscription forwarding) is V2. Validate polling cadence/comfort on hardware (M0c). |
| R7 | Out-of-headset alerting (agent done while headset off). | **Out of V1 scope** — owned by the desktop app's notifications; no APNs work in this client. |
| R8 | **Dictation accuracy** unproven for technical prompts; on-device STT silently falls back to server. | Co-equal modalities; M0d WER gate; detect/disclose server fallback (privacy). |
| R9 | **Distribution / App Review** for an internal visionOS app. | §18; TestFlight channel; pre-empt Guideline 4.2/2.1. |
| R10 | **Server-contract drift** with no auto-updater + hand-typed models. | Compat policy + version-header tripwire; SuperJSON handling. |
| R11 | **Host-service-stream over backgrounding** has no reference client. | Stream contract + hardware spike folded into M0c. |
| R12 | Presentation/domain boundary leaks → breaks spatial path. | NG7; device-local presentation state; M0 seam discipline. |

---

## 16. Resolved Design Details

1. **Watch UI** — full-fidelity transcript (ambient + lean-in, §9) of the **agent's own** activity from host-service over relay; bounded renderers + generic fallback; oversized → explicit "open full" host fetch. User-initiated review browsing is V1.1.
2. **Deep-links & scene restoration** — reuse `superset://` with `superset://workspace/<id>`, `superset://project/<id>`, `superset://session/<chatSessionId>`, **and `superset://auth/callback?token=…`** (auth handoff). Router maps path → `(sceneKind, domainId)`; value-keyed scenes give open-or-focus. Restoration restores **intent** (run the normal load + re-auth + re-open the host stream), not just geometry; a restored window onto a deleted Workspace shows a **404 surface**, not a spinner.
3. **Onboarding (FR-ONB)** — lightweight, skippable, replayable **5-beat**: gaze+pinch, switcher/palette (Cmd+K), **host-online state**, open first Workspace, window-vs-pane close. No-Host orgs get a "connect a Host" terminal state; acceptance is conditioned on a reachable Host.
4. **Settings scope** — minimal editable set; hosts/projects/billing/account read-only; host/macOS-specific cut (see §7.2).
5. **V1→V2 boundary** — minimum-viable seam; no speculative spatial abstraction until V1 learnings.
6. **Status liveness** — open Workspaces **poll `chat.getDisplayState` over the relay** for near-live transcript; the list polls cloud tRPC. No live subscription / cloud-push in V1; true streaming + the cloud Durable Stream are V2.

---

## 17. Success Metrics

**Acceptance (V1 ship gates).** Every M0* gate below is **auto-verifiable**: `xcodebuild` build + test + a **Simulator** launch — **no real-hardware launch is required per gate or per PR**. Real Vision Pro hardware verification is a **single batched human pass (M-HW)** before V1 ship, not a per-issue gate.
- **M0 — Renderer seam (minimum-viable):** same store drives the 2D adapter + a throwaway second adapter, zero domain change. Hard gate.
- **M0a — Auth handoff (Simulator):** system-browser sign-in → token in Keychain → a cloud call AND a host-service-over-relay call succeed; org switch via `setActive()` without re-auth. Hard gate.
- **M0c — Watch (Simulator):** open a Workspace against a **live Host**, render the transcript from host-service `getDisplayState`/`listMessages` over the relay, and **refresh (poll) across a backgrounding cycle without blanking**. Hard gate.
- **M0d — Prompt + dictation bar:** voice-dictate a real technical prompt, review, send, see the run; dictation meets the WER bar on a fixed prompt set or ships disabled/keyboard-first.
- **M0e — Lifecycle:** create + delete a Workspace against a live Host (org with an active/trialing sub); rename Host-offline.
- **M-HW — Batched hardware QA (human, once before V1 ship):** install the build on a real Vision Pro and confirm the core loops launch and work. **Not** a per-issue/PR gate — the autonomous loop never blocks on it.

**Product (dogfood — qualitative + behavioral):**
- **M1** time-to-first-meaningful-view — **target (initial, validate): < 3s warm (token in Keychain → first Workspace surface), < 15s cold (incl. sign-in)**; onboarding effectiveness (incl. host-online beat).
- **M2** comfort/fatigue + task completion + preference (descriptive).
- **M3** multi-window engagement = **per-window focus/foreground time** (visionOS exposes no raw gaze; never log gaze) excluding structurally-forced pairs; collapse-to-single-window tripwire. Transport: **PostHog**.
- **M4** median comfortable session length — **target (initial, validate): ≥ 20 min sustained in the watch loop without removal**.
- **M-Host** % of sessions with a live Host tunnel (validates the host-awake assumption); requires each test org on an active/trialing plan.

---

## 18. Distribution & App Review

**Decision:** committed — TestFlight is the V1 channel and we take on the App Review prep below. **Owner: TBD (assign early — review has lead time).**

- **Channel:** TestFlight is the dogfood distribution channel (no enterprise sideload on Vision Pro). Track the 90-day build expiry.
- **App Review risk:** a remote-control client risks Guideline **4.2** (minimum functionality) and **2.1** (demo account). Pre-stage a **demo account + a reachable always-on Host + reviewer notes**; budget the first review cycle; the watch-without-host *list* surface helps 4.2.
- **Entitlements:** Speech recognition + microphone (dictation), background networking for the host-service stream; declare them with usage strings.

---

## Decision log

- **ADR-0001** — Hybrid rendering — **superseded by 0003**.
- **ADR-0002** — Web-primary cookie-session auth — **superseded by 0005**.
- **ADR-0003** — Native SwiftUI workspace UI — accepted.
- **ADR-0004** — V1 polling + host reads, not Electric/Durable-Stream — accepted.
- **ADR-0005** — Bearer-token auth via system-browser handoff — accepted (supersedes 0002).
- **ADR-0006** — V1 host-awake; watch & history Host-gated — accepted.
- **ADR-0007** — On-device observability — accepted.
- **ADR-0008** — Optic ID-gated access, per-user device — accepted.
- **ADR-0009** — Rich transcript content via WKWebView (markdown/syntax/diff) — accepted (scoped exception to 0003).
- **ADR-0010** — Client-owned chat sessions for V1 (mint+persist per workspace; cross-client discovery deferred to V2) — accepted.
