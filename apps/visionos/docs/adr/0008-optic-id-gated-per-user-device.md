# 0008 — Optic ID-gated access (per-user device)

**Status:** accepted

V1 gates app access and the stored session credential behind **Optic ID** (via the LocalAuthentication framework): on launch/foreground, the wearer authenticates and sees their own Superset workspaces ("put it on, see your work"). We model the headset as a **per-user device** — the user's own Apple Account and Superset login. We chose this because it's a strong, native, low-friction security story and it protects the high-value session credential / relay JWT, which carry RCE-grade host access (§13/ADR-0006), on a device that may be set down.

## Consequences

- **Platform constraint:** Optic ID authenticates the device's **enrolled owner**; visionOS Guest Mode carries no persistent identity. So "a different person puts it on and sees *their* workspaces" is not native face-switching — it works because each user has their own device + login. Shared-headset multi-user-by-face is out of scope.
- Resolves the §13 "single-user-per-install vs Optic ID gate" open question → **Optic ID gate + per-user device**.
- Clear the cached relay JWT on background; re-auth (Optic ID) on foreground — this also mitigates the ~1h JWT revocation lag (§13).
