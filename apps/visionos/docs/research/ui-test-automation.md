# Research: automated UI testing on the visionOS Simulator

Spike answering: **can we drive the visionOS Simulator to exercise the app automatically — in the build loop / CI — to catch crashes and broken flows before the on-device pass?** Short answer: **yes, via XCUITest**, and a smoke test *would have caught* the dictation-auth crash that reached hardware. Sources inline.

## Answer
- **XCUITest is fully supported on the visionOS Simulator** and runs headlessly under `xcodebuild test` ([WWDC25 — UI automation with Xcode](https://developer.apple.com/videos/play/wwdc2025/344/), [XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation)).
- It drives the app through the **accessibility tree**, not simulated input — so it **does not need to simulate eye-gaze/pinch**. When a test calls `.tap()`, visionOS resolves the activation directly. No gaze to fake.
- **Multi-window is testable**: `app.windows` queries open `WindowGroup` scenes, so the window-per-workspace open path can be asserted (assert *existence + contents*, not geometry — the system owns placement).
- **It would have caught our crash**: the dictation trap fires on a real code path (the TCC auth callback in `DictationController`), not anything gaze/hardware-specific. A test that opens a workspace window and toggles the mic hits it.

## The CI cost (the one real tradeoff)
Our current gate (`.github/workflows/visionos-ci.yml`) builds with `-sdk xrsimulator` and **never boots a runtime** (deliberate). UI tests require `xcodebuild test` to **boot a visionOS Simulator runtime** — slower, and the runner must have the runtime installed (`xcodebuild -downloadPlatform visionOS` if missing). Headless is fine (no GUI session needed; Simulator runs in the background since Xcode 9 — [mokacoding](https://mokacoding.com/blog/running-tests-from-the-terminal/)).

```bash
xcrun simctl boot "Apple Vision Pro" || true
xcodebuild test -project Superset.xcodeproj -scheme Superset \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=latest' \
  -resultBundlePath TestResults.xcresult
```

## Two app-side prerequisites
1. **Accessibility identifiers** (none exist today) on the elements the test drives — rail items, workspace-window root/title, composer input + **mic toggle**, auth-gate root.
2. **A `-uiTestMode` launch path**: stub a signed-in session and **pre-grant mic/speech permission** — because the **permission dialog can't be automated on visionOS** (no `springboard` process to tap "Allow" — [forums 759347](https://developer.apple.com/forums/thread/759347)), and the OAuth web flow can't either.

## What stays hardware-only (M-HW)
- **Optic ID / LocalAuthentication** — `canEvaluatePolicy` returns `.unavailable` on the Simulator, so `LockController` degrades to *unlocked* (ADR-0008). The lock flow is **bypassed** in CI — a UI test won't reliably catch lock bugs.
- **Eye-gaze targeting / hover**, **ARKit / immersive**, **live mic + on-device speech quality**, and **spatial comfort / "feel."**

## Snapshot testing
Viable but brittle: [`pointfreeco/swift-snapshot-testing`](https://github.com/pointfreeco/swift-snapshot-testing) supports visionOS, but reference images diff falsely across runtime/Xcode bumps — pin the runtime. **Start with `XCTAttachment` screenshots** (free, in the result bundle) for triage; defer pixel-diffing.

## Third-party tools — skip
**Appium/XCUITest bridge: not supported on visionOS, no plans** ([discuss.appium.io](https://discuss.appium.io/t/is-it-possible-to-automate-apple-vision-pro/40050)). Maestro/Mobile-MCP: no visionOS-sim support. **Native XCUITest is the only mature path.**

## Recommendation (the loop gate)
Add an XCUITest target whose `xcodebuild test` the worker already runs on the Mac — a **smoke flow**: launch (uiTestMode) → assert workspace list → tap a rail workspace → assert a **second window** opened → focus composer → **tap the dictation mic** → assert the app is still alive (a surviving query *after* the mic tap is the crash gate). Then wire CI to boot the runtime and run it. This upgrades the loop's external verifier from "builds + launches" to "**builds + navigates + opens a window + survives the dictation path**" — closing the exact gap that let the crash through. Optic ID + spatial feel remain the M-HW pass's job.

*Spike completed 2026-06-22. Sources inline.*
