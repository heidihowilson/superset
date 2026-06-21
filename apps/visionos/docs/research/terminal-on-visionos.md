# Research: a terminal on visionOS — libghostty, SwiftTerm, or neither

Spike for #34 (epic #30). Deliverable is a recommendation, not code. Decides how — and whether — to build the V1.1 terminal (PRD NG3; the V1.1 plan was "PTY-over-relay-WS + backgrounding reconnect").

## Recommendation (TL;DR)

1. **Do not build a faithful interactive terminal as the primary surface in V1.x.** The job on this device is *read-dominant* — watch an agent, occasionally peek at output or fire a short command — and typing is Vision Pro's weakest muscle. Optimizing the app around a faithful 80×24 VT grid optimizes the ~5% write path at the expense of the 95% read path.
2. **Keep the PTY-over-WebSocket _transport_ from the V1.1 plan, but render it into a read-first view**, not a VT grid: Dynamic-Type-scalable, syntax-highlighted, selectable/copyable, reflowable, collapsible, searchable, with "jump to error" and a large-type focus mode on any block. Multiple floating panes (transcript center, build log left, `git diff` right) is the thing a laptop can't do — lean into it.
3. **When a real emulator _is_ needed, use [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), not libghostty** — as an explicit secondary "drop to Shell" escape hatch, never the default.
4. **Pursue libghostty only** if a hard requirement emerges that SwiftTerm can't meet (e.g. 120fps Metal rendering of very busy TUIs) and we accept tracking an alpha API.

## Why not "out-terminal" the obvious option

On Vision Pro the real coding path today is **[Mac Virtual Display](https://support.apple.com/guide/apple-vision-pro/use-mac-virtual-display-tan357ede966/visionos)** — physical keyboard, trackpad, ultrawide, and the user's *own* perfect terminal. A native app that competes with that on terminal fidelity loses. Superset's defensible wedge is exactly what Mac Virtual Display does badly: a calm, spatial, glanceable, large-type, multi-pane **watch-and-direct** surface for agents. The comparable native terminal ([La Terminal](https://www.producthunt.com/products/la-terminal-ssh-client-for-vision-pro)) is loved by *keyboard-present DevOps admins* — not our keyboard-light, watch-mostly persona.

Platform facts behind this:
- In-air typing is a "write-off" without a paired keyboard; Apple's HIG steers to dictation + hardware keyboards ([Virtual keyboards HIG](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards)). Dictation suits "run the tests," not `grep -rEn "foo|bar" src/`.
- visionOS typography rewards generous size, medium weight, flat 2D text, short lines, Dynamic Type ([Typography HIG](https://developer.apple.com/design/human-interface-guidelines/typography)) — the opposite of a dense monospaced grid. Blurry small fonts are a recurring dev complaint in the headset.

## If/when we build a real emulator: SwiftTerm

**Feasibility is settled — a native terminal already runs on visionOS.** [rootshell](https://github.com/kitknox/rootshell) ported libghostty to visionOS (TestFlight, [discussion #4087](https://github.com/ghostty-org/ghostty/discussions/4087)); [La Terminal](https://www.producthunt.com/products/la-terminal-ssh-client-for-vision-pro) is a from-scratch spatial SSH client. The question is *fit and risk*, not possibility.

**SwiftTerm is the low-risk, high-fit native option:**
- Pure Swift, **MIT**, **declares `.visionOS(.v1)` in `Package.swift`**, actively maintained (v1.13.0, Mar 2026), production-proven (Secure Shellfish, La Terminal, CodeEdit).
- Core API is `terminal.feed(byteArray:)` — **a 1:1 fit for "bytes arrive over a WebSocket."** Local-PTY spawning is a separate macOS-only class we simply don't use, so there are **no PTY assumptions** to fight.
- CoreText renderer by default (battle-tested; CPU-bound only for very busy TUIs at spatial sizes — untested for our workload), with a newer optional Metal path.
- Integration: wrap `TerminalView` in a `UIViewRepresentable`, pipe WS frames to `feed(byteArray:)`, route the input delegate back to the socket.

**Why not libghostty for V1.x:** it's the better *engine*, but its embedding C ABI is **MIT yet unstable and untagged** as of mid-2026 — Ghostty 1.3.0 extracted it as a standalone Zig module but explicitly "aren't ready to tag a versioned release," no committed date ([1.3.0 notes](https://ghostty.org/docs/install/release-notes/1-3-0), [libghostty-is-coming](https://mitchellh.com/writing/libghostty-is-coming)). Embedding means pinning a commit and absorbing breaking changes, and the visionOS port required a **Zig stdlib patch** (a maintenance liability) plus a pipes/non-PTY backend. Keep it as a future migration target once it tags a stable release.

**Other options considered:** xterm.js in a `WebView` (MIT, works, but non-native feel + awkward spatial keyboard/IME — fallback only); libvterm (MIT C state machine, but you build the whole view — more work than SwiftTerm for the same result); iTerm2 core (AppKit-only, GPL — not viable).

**Graphics is not a blocker either way:** a Metal-rendered flat view via **CAMetalLayer** is supported in a visionOS 2D window ([Apple forums 746463](https://developer.apple.com/forums/thread/746463)); `MTKView` is unavailable but neither emulator needs it for the windowed case.

## Effort

| Approach | Effort | Notes |
|---|---|---|
| **Read-optimized output view (recommended V1.x)** | Low–Med | Custom SwiftUI view over the WS byte stream; no emulator. Best fit for the job + platform. |
| **SwiftTerm escape hatch** | **Lowest (for a real emulator)** | SPM package, `UIViewRepresentable`, `feed(byteArray:)`, input delegate → socket. visionOS in manifest, MIT, no PTY. |
| **Port libghostty** | High / premature | Best engine, unstable untagged API + Zig stdlib patch. Proven possible (rootshell), but alpha. |

## Open unknowns
- SwiftTerm CoreText CPU cost on very busy TUIs at spatial sizes (its Metal path is newer than CoreText).
- Exact visionOS build triple used by the rootshell libghostty port is undocumented.
- When we commit to building the terminal surface, cut an ADR recording this choice (defer-faithful-terminal + SwiftTerm-over-libghostty) — it's a real, hard-to-reverse trade-off.

*Sources inline. Spike completed June 2026.*
