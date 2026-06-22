# visionOS — Information Architecture (V1.1 revision)

Revises the V1 navigation/IA after first-device dogfooding. Supersedes the relevant parts of PRD §7 (windowing) and §9 (chrome). Decision recorded in [ADR-0011](adr/0011-information-architecture.md). HIG-grounded; sources at bottom.

## Why we're revising

The V1 build ported the **desktop sidebar** verbatim: a fixed 260×520 leading ornament (`WorkspaceSwitcherView`) holding an org-switcher + nav rows + a **nested project→workspace ScrollView**, while the main window *also* renders the same grouped list, and Settings is **one ~10-section `Form`**. On device this reads as iPad/Mac, not visionOS:

- The nav ornament is **too wide** and duplicates the main list.
- A **nested project→session scroll** is the documented anti-pattern (two stacked scroll axes; with many projects it's unusable — gaze-scroll is coarse and rows are 60–80pt).
- **Flat Settings** is the pattern Apple itself retired (macOS Ventura → sidebar master/detail).

## Principles (visionOS HIG)

- **Navigation is a leading-edge tab ornament**, ~1 icon wide, floating *outside* the window — not an in-window panel. Max **6 tabs**; we use **3**.
- **Dozens of items → a searchable sidebar/split view, never tabs.** Search is the primary way in at scale, not scrolling.
- **Two navigation levels max per window**; **one scroll axis per pane**. No detail-of-detail.
- **`NavigationSplitView`** is master/detail: glass-layered columns, sidebar darker for depth. Sidebar ≈ 280–320pt, content ≈ 360–480pt; `.balanced` style.
- **60pt min targets, 60–80pt rows. Always a default selection** (no empty detail panes).
- **New window only for simultaneous, independent contexts**; otherwise push/select. Window-per-workspace stays (the browser is the catalog; each *watched* session gets its own window).

## Target IA (Option A — `sidebarAdaptable` tabs + searchable split views)

```
Leading-ornament TabView  (.tabViewStyle(.sidebarAdaptable), 3 tabs, icons + labels)
├── Workspaces  (default)
│     NavigationSplitView (2-col, .balanced)
│       sidebar : Recents · Active · All           ← pinned pseudo-filters, .searchable("Find a session")
│       detail  : session list for the chosen filter; tap = openWindow(workspace)  ← window-per-workspace
├── Projects
│     NavigationSplitView (2-col, .balanced)
│       sidebar : project list, .searchable("Find a project")   ← picking a project FILTERS
│       detail  : that project's workspaces; tap = openWindow(workspace)
└── Settings
      NavigationSplitView (2-col)
        sidebar : Account · Organization · Appearance · Model · Input · Hosts · Projects · About  (default-selected)
        detail  : the selected category's controls
```

- **Workspaces tab is the home** — answers "get me back into what I was doing" without a project drill-down (Recents pinned at top). This is the top job-to-be-done for an agent control surface.
- **Projects tab** is the project-first entry; picking a project **filters** the session list (no nesting every session under every project).
- The **org-switcher moves out of the nav ornament** into the split-view sidebar header (Workspaces/Projects) and Settings → Organization. It is not app-level navigation.
- `sidebarAdaptable` lets each tab's split view **expand to a full sidebar** on demand — Apple's sanctioned "few destinations + deep hierarchy" shape.

(Considered and rejected: **Option B**, single project-first drill-down — simpler but forces a project pick before resuming a recent session, wrong for the resume-heavy use case. See ADR-0011.)

## Layout sketches (approximate)

The leading **tab ornament floats just outside the window's left edge** (icons only; gazing at one expands its label). The window itself is a 2-column `NavigationSplitView` on glass; the system window bar sits centered beneath it. `◀` marks the active tab/selection.

**Shell — ornament + split-view window**
```
   ornament                       main window (glass)
  ┌────────┐    ┌────────────────────┬─────────────────────────────┐
  │ ▣ Work │    │                    │                             │
  │ ▦ Proj │    │   sidebar          │   detail                    │
  │ ⚙ Sett │    │   (~300pt)         │   (selected item)           │
  └────────┘    │                    │                             │
   (tabs,       └────────────────────┴─────────────────────────────┘
    ~64pt)                     ──────◍──────   ← system window bar
```

**Workspaces tab (default / home)** — Recents·Active·All + search → a *flat* session list; no project nesting.
```
 ┌────────┐  ┌──────────────────────────┬──────────────────────────────┐
 │ ▣ Work◀│  │ ⌕ Find a session         │  pkg/auth-refresh        ⊕   │
 │ ▦ Proj │  ├──────────────────────────┤  acme · running · 2m ago     │
 │ ⚙ Sett │  │ RECENTS                  │                              │
 └────────┘  │  ● pkg/auth-refresh  2m ◀│  ▸ last: "run the tests"     │
             │  ● web-hotfix        1h  │  ▸ 3 files changed           │
             │ ACTIVE                   │   ┌────────────────────────┐ │
             │  ◐ infra-migrate     ⟳   │   │   Open workspace   ⧉   │ │
             │ ALL                      │   └────────────────────────┘ │
             │  ○ docs-pass             │                              │
             └──────────────────────────┴──────────────────────────────┘
                flat list (one scroll)       opens its own window →
```

**Projects tab** — pick/search a project → see *only* that project's workspaces (filter, not nest).
```
 ┌────────┐  ┌──────────────────────────┬──────────────────────────────┐
 │ ▣ Work │  │ ⌕ Find a project         │  superset            12 ws   │
 │ ▦ Proj◀│  ├──────────────────────────┤                              │
 │ ⚙ Sett │  │  superset          12  ◀ │  ● pkg/auth-refresh   2m     │
 └────────┘  │  marketing          3    │  ● web-hotfix         1h     │
             │  infra              5    │  ○ docs-pass                 │
             │  mobile             2    │  ○ …                         │
             │  …                       │                              │
             └──────────────────────────┴──────────────────────────────┘
                projects (searchable)       selected project's workspaces
```

**Settings** — category sidebar + detail pane (the macOS-Ventura / visionOS master-detail).
```
 ┌────────┐  ┌──────────────────────────┬──────────────────────────────┐
 │ ▣ Work │  │  Account                 │  Organization                │
 │ ▦ Proj │  │  Organization         ◀  │   Active:  [ acme        ⌄ ] │
 │ ⚙ Sett◀│  │  Appearance              │   Plan:    PRO               │
 └────────┘  │  Model                   │  ───────────────────────────  │
             │  Input & Notifications   │   Hosts                      │
             │  Hosts                   │   ● Seths-MacBook  online     │
             │  Projects                │                              │
             │  About                   │                              │
             └──────────────────────────┴──────────────────────────────┘
                categories (default-sel)    selected category's controls
```

**Window-per-workspace** — "Open workspace" spawns a *separate* scene you place in space; watch + prompt one agent per window (unchanged from V1).
```
   browser window               workspace window (own scene)
  ┌──────────────┐             ┌───────────────────────────────┐
  │  …split view │             │  pkg/auth-refresh · running    │
  │   (catalog)  │             │ ┌───────────────────────────┐ │
  └──────────────┘             │ │ transcript (web-rendered) │ │
        ↘  arranged in         │ │ …agent messages…          │ │
           a gentle arc        │ └───────────────────────────┘ │
                               │  [ dictate 🎤 ]  prompt…   ▶  │
                               └───────────────────────────────┘
```

## Component plan

| Current | Change |
|---|---|
| `WorkspaceSwitcherView` (260×520 ornament: header+nav+nested list) | **Delete.** Replace with a slim `RootTabView` leading-ornament `TabView(.sidebarAdaptable)`. |
| `RootView` NavigationStack + duplicated list | `RootView` hosts the `TabView`; each tab is its own split view. |
| `WorkspaceListView` (grouped-by-project flat list) | Becomes the **Projects** tab's split view (sidebar: projects + search; detail: that project's workspaces). |
| — (new) | **`WorkspacesBrowserView`** — the Workspaces tab: Recents/Active/All filters + search → flat (un-nested) session list. |
| `SettingsView` (one `Form`, ~10 sections) | **`SettingsSplitView`** — `NavigationSplitView`, category sidebar (default-selected) + per-category detail. Keep the existing section bodies as detail panes. |
| org-switcher in the ornament | Move to split-view sidebar header + Settings → Organization. |

## "Sessions won't open" (bug, fold into this work)

Tapping a workspace must reliably open/focus its window. Audit `WindowRouter.openWorkspace` → `openWindow(id:value:)` against the new entry points, and verify `UIApplicationSupportsMultipleScenes` is honored (it was added to `Info.plist`). Acceptance: from any tab's detail list, selecting a workspace opens its window on device (Simulator + M-HW).

## Slicing (independently shippable)

1. **Leading-ornament `TabView(.sidebarAdaptable)` shell** (Workspaces/Projects/Settings) replacing the wide switcher ornament — nav only, tabs route to placeholder panes.
2. **Projects tab**: 2-col split view (projects + `.searchable` → filtered workspace list); reuse/retire `WorkspaceListView`.
3. **Workspaces tab**: Recents/Active/All + `.searchable` → un-nested session list (the new home).
4. **Settings master/detail**: `NavigationSplitView` category sidebar + detail panes (port the existing `Form` sections).
5. **Fix workspace-open** + org-switcher relocation + delete `WorkspaceSwitcherView`.

Each slice keeps `xcodebuild`+Simulator green; the set gets one batched on-device (M-HW) pass.

## Sources
HIG: [Designing for visionOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos) · [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) · [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) · [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views). SwiftUI: [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) · [sidebarAdaptable tab navigation](https://developer.apple.com/documentation/SwiftUI/Enhancing-your-app-content-with-tab-navigation) · [Presenting windows and spaces](https://developer.apple.com/documentation/visionos/presenting-windows-and-spaces). WWDC: [24 — Elevate your tab and sidebar experience](https://developer.apple.com/videos/play/wwdc2024/10147/) · [24 — Work with windows in SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10149/) · [23 — Elevate your windowed app for spatial computing](https://developer.apple.com/videos/play/wwdc2023/10110/).
