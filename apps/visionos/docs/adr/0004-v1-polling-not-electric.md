# 0004 — V1 native client uses polling + chat stream, not Electric

**Status:** accepted

Against the repo convention (AGENTS.md rule 9: Electric/TanStack-DB cache-first live queries), the V1 native visionOS client deliberately does **not** use Electric. It consumes the HTTP chat stream for live agent output and uses plain cookie-authed tRPC queries with periodic refresh for lists/status, plus non-optimistic mutations for writes. We chose this because the watch loop's liveness comes from the chat stream rather than Electric, lists/status tolerate seconds of staleness at dogfood scale, and a native Swift Electric/TanStack-DB client is substantial net-new infra (the M0-Sync gate).

## Consequences

- Removes the M0-Sync hardware gate from V1; native sync infra shrinks to tRPC + stream consumption.
- Writes are non-optimistic (show a pending state); no `txid` confirmation loop.
- Electric is the planned **V2 upgrade** for true live-queries, optimistic writes, and offline. A future reader should not "add Electric to fix it" without revisiting this trade.
