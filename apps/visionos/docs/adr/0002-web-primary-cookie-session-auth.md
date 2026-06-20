# 0002 — Web-primary cookie-session auth

**Status:** accepted

The V1 app authenticates by running the web login flow in a webview and holding the better-auth **session cookie** natively (shared between `URLSession`'s `HTTPCookieStorage` and the WKWebView `WKHTTPCookieStore`), using cookies for tRPC and chat and minting short-lived JWTs from `/api/auth/token` for Electric/relay — exactly as the web app does — instead of a native OAuth 2.0 + PKCE bearer chain. We chose this because the tRPC context already accepts cookie sessions (`apps/api/src/trpc/context.ts` tries `getSession` before bearer) and the web app already mints Electric JWTs from its session (`apps/web/src/trpc/auth-token.ts`), so the webview panes and native shell can share one proven mechanism.

## Consequences

- Dissolves the four-verifier bearer audit, the custom-scheme PKCE spike, the `TRUSTED_API_CLIENTS` edits, and the refresh-token-rotation blocker. Session revocation (lost/shared headset) is supported by better-auth session management, unlike OAuth refresh-token rotation, which it lacks.
- New work shifts to **cookie sharing across `URLSession`/WKWebView and session-lifetime handling**; the security model is session-cookie-in-protected-storage rather than Keychain-token.
- Independent of rendering tech (survives ADR-0003's pivot to native UI): any native app can hold the session cookie via a login webview / `ASWebAuthenticationSession` + `URLSession` `HTTPCookieStorage`. This invalidates the PRD's original "native client is cookieless" premise, which was the sole basis for the native OAuth/PKCE bearer chain.
- Native OAuth/PKCE is shelved as possible V2 hardening if a truly cookieless native path is ever needed.
