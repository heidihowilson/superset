# 0005 — Bearer-token auth via system-browser handoff (supersedes ADR-0002)

**Status:** accepted (supersedes ADR-0002)

V1 authenticates with a **better-auth session token used as a Bearer**, obtained via a **system-browser handoff** — not a webview cookie. Flow: `ASWebAuthenticationSession` (real Safari, so Google/GitHub OAuth is allowed) → a connect endpoint analogous to the desktop's `/api/auth/desktop/connect` → redirect `superset://auth/callback?token=…&expiresAt=…&state=…` → store the token in **Keychain** → send `Authorization: Bearer <token>` on every API/tRPC call. For relay/host-service calls, **mint a short-lived RS256 JWT from `/api/auth/token`** (authed with the session bearer) — the same token the web app uses for the relay, carrying `organizationIds`.

We chose this because ADR-0002's webview-cookie plan is structurally impossible here: Google blocks OAuth in embedded WKWebViews (`disallowed_useragent`), `ASWebAuthenticationSession` never returns cookies, and the session cookie is `httpOnly`. The repo already proves the Bearer path twice: the desktop `superset://auth/callback?token=` handoff and `apps/mobile`'s `@better-auth/expo` `Authorization: Bearer` pattern, both honored by `apps/api/src/trpc/context.ts` (`getSession`) and the chat `requireAuth`.

## Consequences

- The native sign-in is a brief system-browser pass, not a custom login UI; the token (≈30d `session_token`, **not** the 5-min `session_data` cache cookie) lives in Keychain.
- **Active org is the session's `activeOrganizationId` (via `setActive()`), not the JWT** (which only carries the full membership list, frozen for the mint TTL); the `x-superset-organization-id` header is an optional override.
- There is **no cookie/OAuth refresh endpoint**; on 401, re-run the handoff. Relay/host JWTs are stateless (no revocation lookup) — see ADR-0006/§13 for the revocation-lag and RCE-surface consequences.
- The four-verifier audit / PKCE custom-scheme spike from the original PRD remain dissolved; this is still a token, just obtained correctly.
