# 0005 — Bearer-token auth via system-browser handoff (supersedes ADR-0002)

**Status:** accepted (supersedes ADR-0002)

V1 authenticates by obtaining a better-auth **session credential** via a **system-browser handoff** (real Safari, so Google/GitHub OAuth is allowed) — **not** a WKWebView cookie jar. Flow: system-browser sign-in mirroring the desktop's `/api/auth/desktop/connect` flow (which exists and redirects to `/auth/desktop/success` — **confirm its exact token-delivery hop and mirror it**) → store the credential in the **Keychain** → replay it on every API/tRPC call. The proven in-repo reference is `@better-auth/expo` (`apps/mobile`), which stores the session and replays it as a **`Cookie` header** via `getCookie()` (`apps/mobile/lib/trpc/client.ts:12`); the **`bearer()` plugin is also enabled** (`packages/auth/src/server.ts:778`), so `Authorization: Bearer <session-token>` is an equivalent path. Either way it is a stored credential on native `URLSession` requests, honored by `apps/api/src/trpc/context.ts` `getSession` and the chat `requireAuth`. For relay/host-service calls, **mint a short-lived RS256 JWT from `/api/auth/token`** (carrying `organizationIds`) — the same token the web app uses.

We chose this because ADR-0002's webview-cookie plan is structurally impossible here: Google blocks OAuth in embedded WKWebViews (`disallowed_useragent`), `ASWebAuthenticationSession` never returns cookies to the app, and the session cookie is `httpOnly`. The repo proves the system-browser-handoff + stored-credential pattern via the desktop `/api/auth/desktop/connect` flow and `apps/mobile`'s `@better-auth/expo` replay. (Verified 2026-06-20; note mobile uses a `Cookie` header, not `Authorization: Bearer` — both are accepted server-side.)

## Consequences

- The native sign-in is a brief system-browser pass, not a custom login UI; the token (≈30d `session_token`, **not** the 5-min `session_data` cache cookie) lives in Keychain.
- **Active org is the session's `activeOrganizationId` (via `setActive()`), not the JWT** (which only carries the full membership list, frozen for the mint TTL); the `x-superset-organization-id` header is an optional override.
- There is **no cookie/OAuth refresh endpoint**; on 401, re-run the handoff. Relay/host JWTs are stateless (no revocation lookup) — see ADR-0006/§13 for the revocation-lag and RCE-surface consequences.
- The four-verifier audit / PKCE custom-scheme spike from the original PRD remain dissolved; this is still a token, just obtained correctly.
