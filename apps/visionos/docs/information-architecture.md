# visionOS — Information Architecture (V1.1 revision)

Revises the V1 navigation/IA after first-device dogfooding. Supersedes the relevant parts of PRD §7 (windowing) and §9 (chrome). Decision recorded in [ADR-0011](adr/0011-information-architecture.md). HIG-grounded; sources at bottom.

## Why we're revising

The V1 build ported the **desktop sidebar** verbatim: a fixed 260×520 leading ornament (`WorkspaceSwitcherView`) holding an org-switcher + nav rows + a **nested project→workspace ScrollView**, while the main window *also* renders the same grouped list, and Settings is **one ~10-section `Form`**. On device this reads as iPad/Mac, not visionOS:

- The nav ornament is **too wide** and duplicates the main list.
- A **nested project→session scroll** is the documented anti-pattern (two stacked scroll axes; with many projects it's unusable — gaze-scroll is coarse and rows are 60–80pt).
- **Flat Settings** is the pattern Apple itself retired (macOS Ventura → sidebar master/detail).

## Principles (visionOS HIG)

- **Navigation is a leading-edge icon rail** — **icons only by default**, the label revealed on hover/gaze (`.help()` + hover effect), ~1 icon wide, floating *outside* the window. Mirrors the desktop left nav (Org · Workspaces · Automations · Tasks & PRs · Settings · ＋New). This is the fix for "too wide": a rail, not a 260pt panel.
- **Workspaces is a collapsible project→workspace tree.** Group by **project only** (no status grouping); each project is **foldable** so the list stays short (collapse what you're not in) — that's what makes a nested list work on visionOS vs. the V1 always-expanded scroll. Optional search filters. **Tap a workspace → its own window.**
- **One scroll axis per pane**; the tree is the single scroll surface (no detail-of-detail).
- **`NavigationSplitView` for Settings** (master/detail): glass-layered columns, sidebar darker for depth. Sidebar ≈ 280–320pt, detail ≈ 360–480pt.
- **60pt min targets, 60–80pt rows. Default selection** in master/detail (no empty pane).
- **New window only for simultaneous, independent contexts.** Window-per-workspace stays: the rail+tree is the catalog; each *watched* session gets its own window. **Multi-window only** — opening a workspace always opens/focuses its own window; the single-window-plus-switcher model is retired (the explicit "consolidate windows" action remains as the proliferation mitigation).

## Target IA — desktop-mirroring icon rail + collapsible project tree

**Leading ornament = an icon rail** (icons only by default; label on hover/gaze). Mirrors the desktop left nav, top to bottom:

```
⬡  Org            org-switcher — tap = switch org · Sign out
▣  Workspaces ◀   default; shows the collapsible project→workspace tree
◷  Automations    (soon)
▤  Tasks & PRs    (soon)
⚙  Settings       opens the master/detail Settings window
＋ New Workspace   action (create)
```

- **Icons only by default**; the title appears on **hover** (`.help()` tooltip + hover effect) and on gaze. ~1 icon wide — the "too wide" fix.
- **Projects are NOT a rail item** — they're the grouping *inside* Workspaces.
- **Settings is a rail item** (the ⚙ gear, directly below Tasks & PRs — not the Org menu); it opens as its own master/detail window.

**Workspaces content pane = a collapsible project→workspace tree** (mirrors the desktop sidebar, done right for visionOS):

```
▾ project A                    ← foldable header (DisclosureGroup), one per project
   ●  workspace 1   running
   ●  workspace 2   idle
▸ project B   (3)              ← collapsed; count hint
▾ project C
   ◐  workspace 4   running
```

- **Foldable per project** — collapse the ones you're not in, so the list stays short (vs. the V1 always-expanded scroll). Fold state persists per window.
- **No status grouping** — group by project only; status is a per-row indicator (dot + label), never a section.
- **Tap a workspace → opens it in a NEW window** (window-per-workspace, unchanged). One scroll axis (the tree); rows 60–80pt; optional `.searchable` to filter when there are many projects.

**Settings** (the ⚙ rail item) = a 2-column `NavigationSplitView` master/detail: category sidebar (Account · Organization · Appearance · Model · Input & Notifications · Hosts · Projects · About · Debug), default-selected, + the selected category's controls. **Debug** opens a plain-text dump of the workspace store in its own window.

Automations and Tasks & PRs are rail items now, but their panes are placeholders until wired.

## Layout sketches (approximate)

The leading **icon rail floats just outside the window's left edge** — icons only; the label appears on hover/gaze. `◀` marks the active rail item / selection.

**Shell — icon rail + content window**
```
   rail (icons only;       content window (glass)
   label on hover/gaze)
  ┌─────┐   ┌───────────────────────────────────────────────────┐
  │ ⬡   │   │  Workspaces                                  ⌕     │
  │ ▣ ◀ │   │  ▾ superset                                        │
  │ ◷   │   │     ●  pkg/auth-refresh     running   2m    →⧉     │
  │ ▤   │   │     ●  web-hotfix           idle      1h    →⧉     │
  │ ⚙   │   │  ▸ marketing          (3)                          │
  │ ＋  │   │  ▾ infra                                           │
  └─────┘   │     ◐  infra-migrate        running   ⟳     →⧉     │
   ~64pt    │     ○  db-backfill          stopped         →⧉     │
            └───────────────────────────────────────────────────┘
                            ──────◍──────  ← system window bar
  hover labels:  ⬡ Org · ▣ Workspaces · ◷ Automations · ▤ Tasks & PRs · ⚙ Settings · ＋ New
```

**Workspaces — collapsible project tree** (the default pane). Fold per project; status is a row dot, not a section; tap a workspace (→⧉) opens its own window.
```
 ┌─────┐  ┌──────────────────────────────────────────────────────┐
 │ ⬡   │  │  Workspaces                                    ⌕      │
 │ ▣ ◀ │  │  ▾ superset                                           │
 │ ◷   │  │      ●  pkg/auth-refresh        running   2m    →⧉    │
 │ ▤   │  │      ●  web-hotfix              idle      1h    →⧉    │
 │ ⚙   │  │  ▸ marketing             (3)                          │  ← collapsed
 │ ＋  │  │  ▾ infra                                              │
 └─────┘  │      ◐  infra-migrate           running   ⟳     →⧉    │
          │      ○  db-backfill             stopped         →⧉    │
          │  ▸ mobile                (2)                          │
          └──────────────────────────────────────────────────────┘
            foldable per project · grouped by project only · tap = new window
```

**Org menu** — tap the ⬡ rail item.
```
 tap ⬡ →  ┌────────────────────────┐
          │  ✓ acme           PRO  │   switch active org
          │    other-org           │
          │  ────────────────────  │
          │  ⎋  Sign Out           │
          └────────────────────────┘
```

**Settings** — its own window (from the ⚙ rail item): category sidebar + detail pane (macOS-Ventura / visionOS master-detail).
```
 ┌──────────────────────────┬──────────────────────────────┐
 │  Account                 │  Organization                │
 │  Organization         ◀  │   Active:  [ acme        ⌄ ] │
 │  Appearance              │   Plan:    PRO               │
 │  Model                   │  ─────────────────────────── │
 │  Input & Notifications   │   Hosts                      │
 │  Hosts                   │   ●  Seths-MacBook  online    │
 │  Projects                │                              │
 │  About                   │                              │
 └──────────────────────────┴──────────────────────────────┘
   categories (default-sel)     selected category's controls
```

**Window-per-workspace** — tapping a workspace spawns a *separate* scene you place in space; watch + prompt one agent per window (unchanged from V1).
```
   rail + tree (catalog)        workspace window (own scene)
  ┌─────┬──────────┐           ┌───────────────────────────────┐
  │ ▣◀  │ ▾ proj   │           │  pkg/auth-refresh · running    │
  │⬡◷▤⚙ │   ● ws →⧉│ ───────▶  │ ┌───────────────────────────┐ │
  │ ＋  │ ▸ proj   │           │ │ transcript (web-rendered) │ │
  └─────┴──────────┘           │ │ …agent messages…          │ │
        ↘ arranged in          │ └───────────────────────────┘ │
          a gentle arc         │  [ dictate 🎤 ]  prompt…   ▶  │
                               └───────────────────────────────┘
```

## Component plan

| Current | Change |
|---|---|
| `WorkspaceSwitcherView` (260×520 ornament: header + nav + nested list) | **Rebuild as a slim icon-rail leading ornament** (`RootRailView`): ⬡ Org · ▣ Workspaces · ◷ Automations · ▤ Tasks & PRs · ⚙ Settings · ＋ New — **icons only**, label on hover (`.help()` + hover effect). |
| `RootView` (NavigationStack + duplicated list) | Hosts the rail ornament + a **content pane switched by the selected rail item** (Workspaces tree; Automations/Tasks placeholders). |
| `WorkspaceListView` (grouped-by-project flat list) | Becomes the **collapsible project→workspace tree**: a `DisclosureGroup` per project (fold state persisted), workspaces beneath; **no status grouping**; tap a workspace → **new window**. Optional `.searchable`. |
| `SettingsView` (one `Form`, ~10 sections) | **`SettingsSplitView`** — `NavigationSplitView` master/detail, **opened from the ⚙ rail item**; default-selected category; existing section bodies become detail panes. A **Debug** category opens the store dump in its own window. |
| org-switcher | **Stays in the rail** as the ⬡ Org item; its menu carries switch-org + Sign out (Settings is its own ⚙ rail item). |

## "Sessions won't open" (bug, fold into this work)

Tapping a workspace must reliably open/focus its window. Audit `WindowRouter.openWorkspace` → `openWindow(id:value:)` against the new tree, and verify `UIApplicationSupportsMultipleScenes` is honored (added to `Info.plist`). Acceptance: tapping a workspace in the tree opens its window on device (Simulator + M-HW).

## Slicing (independently shippable)

1. **Icon-rail ornament shell** (`RootRailView`): ⬡ Org · ▣ Workspaces · ◷ Automations · ▤ Tasks & PRs · ＋ New — icons-only + hover labels; the rail switches the content pane (Automations/Tasks → placeholders). Replaces the wide `WorkspaceSwitcherView`.
2. **Workspaces collapsible tree**: rebuild the content pane as a `DisclosureGroup`-per-project tree with workspaces beneath — no status grouping, tap → new window, fold state persisted, optional search.
3. **Org menu**: ⬡ Org → switch-org + **Settings** + Sign out; org-switcher lives in the rail.
4. **Settings master/detail**: `NavigationSplitView` category sidebar + detail panes (port the existing `Form` sections), opened from the Org menu.
5. **Fix workspace-open** + delete `WorkspaceSwitcherView` + remove the duplicate list.

Each slice keeps `xcodebuild`+Simulator green; the set gets one batched on-device (M-HW) pass.

## Sources
HIG: [Designing for visionOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos) · [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) · [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) · [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views). SwiftUI: [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) · [sidebarAdaptable tab navigation](https://developer.apple.com/documentation/SwiftUI/Enhancing-your-app-content-with-tab-navigation) · [Presenting windows and spaces](https://developer.apple.com/documentation/visionos/presenting-windows-and-spaces). WWDC: [24 — Elevate your tab and sidebar experience](https://developer.apple.com/videos/play/wwdc2024/10147/) · [24 — Work with windows in SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10149/) · [23 — Elevate your windowed app for spatial computing](https://developer.apple.com/videos/play/wwdc2023/10110/).
