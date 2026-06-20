# 0007 — On-device observability (crash + watch-loop telemetry)

**Status:** accepted

The visionOS app ships with on-device crash reporting and structured telemetry from day one: **Sentry's visionOS SDK** (or MetricKit) for crashes/hangs, and structured logging of stream/host-call outcomes (connect, resume, drop, host-offline, latency) so the core reliability risks are measurable in the field. Product metrics (M1–M4, M-Host) emit to **PostHog**, the pipeline already used by web/mobile/desktop.

We chose this because the rest of the monorepo standardizes on Sentry (relay/admin) + PostHog (web/mobile/desktop), the PRD's top reliability risks (host-call/stream resilience) cannot be measured without it, and a remote-control client failing silently in the field is unacceptable.

## Consequences

- **Never log gaze** (§13 privacy invariant). M3 is per-window focus/foreground time, not raw gaze (visionOS does not expose gaze anyway).
- One named owner reconciles which pipeline emits which metric; add the Speech/mic + background entitlements to the build alongside.
