# visionOS / Apple Vision Pro Skills

A curated set of vendored agent skills for **native visionOS (Apple Vision Pro)**
development — Swift, SwiftUI, RealityKit, and ARKit. Installed via the
[`skills`](https://skills.sh) CLI; provenance and hashes are tracked in
[`/skills-lock.json`](../../skills-lock.json).

These live in `.agents/skills/` (the canonical source) and are surfaced to every
agent through the `.claude/skills` symlink, so Claude Code, Codex, Cursor, and
OpenCode all see them.

> **Fork note:** this is a fork we may propose merges to upstream from. All
> vendored skills below are **MIT-licensed**, so redistribution is clean — keep
> the upstream `SKILL.md` files unmodified (don't reformat them) so future
> `npx skills update` stays a clean fast-forward, and keep this attribution file
> with them.

## Installed (selected 2026-06-19)

| Skill | Source repo | License | Why it's here |
|-------|-------------|---------|---------------|
| `realitykit-visionos-developer` | [tomkrikorian/visionosagents](https://github.com/tomkrikorian/visionosagents) | MIT | RealityKit router for visionOS 27 — components, `RealityView`, anchoring, portals, USD bridge. Ships ~30 per-component reference files. |
| `arkit-visionos-developer` | [tomkrikorian/visionosagents](https://github.com/tomkrikorian/visionosagents) | MIT | `ARKitSession` setup, authorization, provider selection (hand/world/plane/image tracking), anchor reconciliation, RealityKit bridge. |
| `spatial-swiftui-developer` | [tomkrikorian/visionosagents](https://github.com/tomkrikorian/visionosagents) | MIT | Spatial SwiftUI — `Model3D` vs `RealityView`, `ImmersiveSpace`/volumes lifecycle, attachments, spatial gestures, layout. |
| `visionos-widgets` | [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills) | MIT | WidgetKit for visionOS — mounting styles, glass/paper textures, proximity-aware layouts. Best self-contained skill of the set. |
| `visionos-design-guidelines` | [ehmo/platform-design-skills](https://github.com/ehmo/platform-design-skills) | MIT | The only true visionOS skill grounded in Apple's HIG — ~50 tagged rules across spatial layout, eye/hand input, windows, volumes, immersive spaces, ornaments, a11y. |
| `swiftui-expert-skill` | [avdlee/swiftui-agent-skill](https://github.com/avdlee/swiftui-agent-skill) | MIT | Foundation. Strongest SwiftUI skill — review + implement + Instruments `.trace` profiling. (Antoine van der Lee.) |
| `swift-concurrency` | [avdlee/swift-concurrency-agent-skill](https://github.com/avdlee/swift-concurrency-agent-skill) | MIT | Foundation. Swift 6 strict-concurrency / actors / `Sendable`; applies to visionOS verbatim. |

The first five are visionOS-specific; the last two are Swift foundations shared
by any Apple-platform app (visionOS is SwiftUI + Swift concurrency underneath).

## Considered and deliberately skipped

- **`charleswiltgen/axiom` RealityKit triad** (`axiom-realitykit` / `-ref` / `-diag`,
  MIT, 986★) — genuinely excellent, especially the diagnostic decision-trees. Skipped
  because its skills.sh slugs don't map to installable units: the content is bundled
  inside the broad cross-platform `axiom-graphics` skill (Metal/SceneKit/etc.), which
  is the wrong shape for a visionOS-pure set. **To add it anyway:**
  `npx skills add charleswiltgen/axiom@axiom-graphics`.
- **`dpearson2699/swift-ios-skills@realitykit`** (769★, ~1.5K installs) — high quality
  but **iOS-targeted by design**; its own "Platform Boundaries" section explicitly
  defers visionOS (`ARKitSession`/`WorldTrackingProvider`) elsewhere. Wrong platform.
  (Also PolyForm Perimeter license — not fully open.)
- **`fusengine/agents@visionos`** — generic filler, requires unavailable proprietary
  sub-agents/MCP, and targets visionOS 26 (behind the others' v27).
- **`twostraws/swiftui-pro`** & **`dimillian/swiftui-performance-audit`** — both strong,
  but redundant once `swiftui-expert-skill` is installed.

## Optional add-ons (not installed)

- `npx skills add tomkrikorian/visionosagents@coding-standards-enforcer` — Swift 6.2
  strict-concurrency / `@Observable` review enforcement (general modern-Swift, not
  spatial-specific).
- The full `tomkrikorian/visionosagents` tree (22 skills) — the three routers above
  cross-link sibling skills (e.g. `realitykit-rendering-materials`,
  `arkit-hand-tracking-provider`) that aren't installed. They degrade gracefully, but
  for full routing fidelity pull the whole `skills/` tree from that repo.

## Maintenance

```bash
npx skills check     # see available updates
npx skills update    # update vendored skills to latest
```

Re-run from the repo root so updates land in `.agents/skills/` and `skills-lock.json`
stays accurate.
