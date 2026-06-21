# 0010 — Client-owned chat sessions for V1 (no cross-client discovery)

**Status:** accepted

V1 Watch and Prompt operate on a **client-minted chat session per workspace**. The visionOS client generates a session id (UUID), creates it via `chat.createSession` (which accepts a **client-supplied** id — `packages/trpc/src/router/chat/chat.ts`), and **persists the `workspaceId → sessionId` mapping in UserDefaults**, reusing it across launches. `chat.getDisplayState` / `listMessages` / `sendMessage` (host-service over the relay) all use that id.

We chose this because there is **no sanctioned way for a no-Electric V1 client to *discover* an existing session for a workspace** — the cloud chat router exposes no list/query-by-workspace, every host-service chat procedure requires a `sessionId`, `v2Workspace.list` carries no session reference, and the desktop finds sessions only via Electric sync of `chat_sessions` (which V1 lacks, ADR-0004). The worker on #4 correctly escalated this gap rather than guess.

## Consequences

- The headset watches and directs the session **it owns** for a workspace — the loop the headset persona actually performs (start + watch your own agent from the headset).
- **Cross-client session discovery** (watching a session started on desktop/elsewhere) is **deferred to V2** — it needs either a cloud `chat.listByWorkspace` query (a backend addition requiring a deploy we don't control from this fork) or the native Electric `chat_sessions` read (M0-Sync, deferred). Neither is in V1's client-only scope.
- Unblocks #4 (Watch) and #5 (Prompt) with **no backend change** — only existing live procedures.
- A general constraint surfaced: the loop can build client code against the **live** Superset API but cannot add new backend capabilities; features needing new server procedures are inherently V2 / human-gated.
