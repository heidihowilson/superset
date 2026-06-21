# visionOS — Distribution & App Review runbook

Operationalizes PRD §18. Closes the "prep" half of #12; the actual TestFlight upload + App Review submission are executed by a human following this doc (they are not code and produce no PR).

## Channel
- **TestFlight** is the only distribution channel — there is **no enterprise sideload on Apple Vision Pro**.
- TestFlight builds **expire after 90 days** — track and re-upload before expiry for the dogfood cohort.

## Prerequisites
- Apple Developer Program membership; an **App Store Connect** app record for bundle id **`sh.superset.visionos`**.
- Set **`DEVELOPMENT_TEAM`** for device/archive builds (Xcode signing, or an untracked xcconfig / `xcodebuild` override). Simulator/CI builds stay unsigned (`CODE_SIGNING_ALLOWED[sdk=xrsimulator*]=NO`, already in `project.yml`).
- Dogfood **orgs must be on an `active`/`trialing` plan** — host access (relay) is plan-gated, so a free-plan tester's host calls 403 (PRD §4).

## Entitlements / usage strings (already in `Info.plist` — verify present)
- `NSFaceIDUsageDescription` — Optic ID unlock (ADR-0008)
- `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` — voice dictation (ADR none; §9)
- `CFBundleURLTypes` → `superset://` scheme — cold-start deep links / auth callback (ADR-0005)
- *Open:* if background polling/stream continuation is added later, declare the appropriate `UIBackgroundModes` — **not** included now (foreground-driven V1; keep the review surface minimal).

## App Review prep (pre-empt the likely rejections)
- **Guideline 4.2 (minimum functionality):** a remote-control client can read as "thin." Lean on the surfaces that work **without** a reviewer-side host — the **Workspace/Project browser** renders from cloud data standalone. Show it first.
- **Guideline 2.1 (demo account):** App Review cannot supply their own Host. Provide:
  1. a **demo Superset account** (on an active/trial plan),
  2. a **reachable, always-on demo Host** dialed into the relay for the review window,
  3. **reviewer notes** (below).
- Note that gaze is used only for system targeting (privacy), and that execution is remote (no on-device code execution).

### Reviewer notes template
> Superset for Vision Pro is a spatial control surface for AI coding agents that run on a remote developer machine ("Host"). Sign in with the provided demo account (Apple ID not required). The demo Host is online for the review period. Open a Workspace to watch an agent's chat transcript and send prompts by voice or keyboard. Window-per-workspace multi-window is the core spatial feature. No code runs on the device; all execution is on the remote Host over an authenticated tunnel.

## Build & upload
1. `xcodegen generate` in `apps/visionos/` (project is generated from `project.yml`).
2. Archive for visionOS (signed with `DEVELOPMENT_TEAM`); upload via Xcode Organizer or Transporter.
3. Add internal testers in App Store Connect → TestFlight; distribute the build.

## Gate before external distribution
- Complete the **M-HW** batched hardware QA (PRD §17): install on a real Vision Pro and confirm the core loops launch and work. The autonomous loop only validates Simulator + `xcodebuild`.
- Resolve open security follow-up **#24** (relay-token seal race) before any non-dogfood distribution.

## Owner
**TBD — assign early** (App Review has lead time; the 90-day expiry needs an owner).
