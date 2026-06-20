# 0005 — Bearer-token auth via system-browser handoff (supersedes ADR-0002)

**Status:** accepted (supersedes ADR-0002)

V1 reuses the desktop's **token-handoff flow** essentially verbatim. **Verified flow:** `ASWebAuthenticationSession` (real Safari → Google/GitHub OAuth allowed) opens **`/api/auth/desktop/connect?provider=…&state=…&protocol=superset`** (a generic, existing endpoint that only allows google/github) → OAuth → **`/auth/desktop/success`** mints a **better-auth session-table token** (`db.insert(sessions)`, 30-day expiry) and deep-links **`superset://auth/callback?token=…&expiresAt=…&state=…`** → ASWebAuthenticationSession captures the `superset://` callback → store the token in the **Keychain** → send **`Authorization: Bearer <token>`** on every API/tRPC call. The desktop does exactly this (`apps/desktop/.../chat-runtime-service/index.ts:52`; `main.ts:125`: "bearer token auth, not web cookies"); it works via the enabled `bearer()` plugin (`packages/auth/src/server.ts:778`) resolving the session through `getSession`. For relay/host-service calls, mint a short-lived RS256 JWT from `/api/auth/token` (carrying `organizationIds`).

We chose this because ADR-0002's webview-cookie plan is structurally impossible here: Google blocks OAuth in embedded WKWebViews (`disallowed_useragent`), `ASWebAuthenticationSession` never returns cookies to the app, and the session cookie is `httpOnly`. The desktop already ships exactly the flow we need, so visionOS reuses the `/api/auth/desktop/connect` endpoint as-is — only registering the `superset://` scheme and capturing the callback. (Fully verified against code 2026-06-20; `apps/mobile`'s `@better-auth/expo` Cookie-header replay is an alternative, but the desktop Bearer flow is the native-designed reference.)

## Consequences

- The native sign-in is a brief system-browser pass, not a custom login UI; the token (≈30d `session_token`, **not** the 5-min `session_data` cache cookie) lives in Keychain.
- **Active org is the session's `activeOrganizationId` (via `setActive()`), not the JWT** (which only carries the full membership list, frozen for the mint TTL); the `x-superset-organization-id` header is an optional override.
- There is **no cookie/OAuth refresh endpoint**; on 401, re-run the handoff. Relay/host JWTs are stateless (no revocation lookup) — see ADR-0006/§13 for the revocation-lag and RCE-surface consequences.
- The four-verifier audit / PKCE custom-scheme spike from the original PRD remain dissolved; this is still a token, just obtained correctly.
