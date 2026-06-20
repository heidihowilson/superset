# 0006 — V1 is host-awake; watch and history are host-gated

**Status:** accepted

V1 assumes the user's **Host is awake and reachable** (headset worn at the desk, or a remote Host kept running). **Watch, chat history, prompting, and lifecycle are all Host-gated**; the only Host-independent surface is the cloud Workspace/Project list. When the Host is unreachable, V1 shows the list plus an explicit "Host offline" state — it is not useful as a roaming, host-asleep companion. **Prompts are never queued offline.**

We chose this because the original "watch is Host-resilient via the cloud Durable Stream" thesis is false in the codebase: `appendToStream`/`ensureStream` (`apps/api/src/app/api/chat/lib.ts`) have **zero callers**, no client reads the stream, live chat actually flows over Electron IPC from an in-memory Host runtime (`packages/chat/src/server/trpc/service.ts`), and history lives in the Host's Mastra memory (there is no `chat_messages` table). Making watch Host-resilient would require building a net-new cloud producer + consumer + history store — explicitly **declined for V1**.

## Consequences

- Watch/history read from **host-service over the relay** (Host-gated), like the web app's `host-client.ts`; the cloud Durable Stream is unused in V1.
- The persona reframes from "roaming second screen" to "spatial control surface for a live Host." The roaming/host-asleep use case is out of V1 scope.
- Reverses ADR-0001's thin-shell "live data is web" framing and the PRD's original host-resilience claims (§2/§6.3/G2/R1/M0c rewritten).
- No-offline-prompt-queuing follows directly: with the agent on the Host, there is nothing to send to when the Host is down; queueing stale prompts at an autonomous agent is unsafe. A cloud-mediated **host-wake** is a possible future differentiator (roadmap), not V1.
- Building the Durable Stream producer/consumer is the clean **V2** path to true host-resilient watch.
