# 0011 — visionOS information architecture: ornament tabs + searchable split views

**Status:** accepted (V1.1 — supersedes the V1 desktop-sidebar port)

App navigation is a **leading-ornament `TabView` with `.tabViewStyle(.sidebarAdaptable)`** carrying **three** fixed destinations — **Workspaces · Projects · Settings**. Each tab is a **2-column `NavigationSplitView`** (master/detail) with `.searchable` as the scale mechanism. Workspace browsing never nests a project→session scroll: the **Projects** sidebar *filters* a flat workspace list, and the **Workspaces** tab (the default/home) is Recents/Active/All + search over an un-nested session list. **Settings** becomes a category-sidebar + detail-pane split view (the macOS-Ventura/visionOS pattern), replacing the single ~10-section `Form`. Window-per-workspace is unchanged — the browser is the catalog; each watched session opens its own window. Full spec: [`../information-architecture.md`](../information-architecture.md).

We chose this because the V1 build transcribed the **desktop sidebar** (a fixed 260×520 leading ornament with a nested project→workspace `ScrollView`, duplicated by the main window) and a **flat Settings `Form`** — both read as iPad/Mac on device and break visionOS guidance: nav belongs in a slim leading ornament (not a wide in-window panel), dozens of items belong behind search in a sidebar (not a nested double-scroll), and many top-level destinations cap at 6 tabs with `sidebarAdaptable` as Apple's sanctioned "few destinations + deep hierarchy" answer.

## Consequences

- Kills the two anti-patterns dogfooding surfaced: the over-wide duplicate nav ornament and the unusable nested project→session scroll. Navigation is two levels max, one scroll axis per pane, 60–80pt rows, default selection everywhere.
- **Workspaces-as-home** optimizes the resume-a-recent-session job (top JTBD for an agent control surface) without forcing a project drill-down.
- Requires rebuilding the nav shell (`RootView`/`WorkspaceSwitcherView` → `RootTabView`), splitting `WorkspaceListView` into Projects/Workspaces tabs, and converting `SettingsView` to a split view — sliced into 5 independently shippable PRs (see spec).
- The **"sessions won't open"** bug is folded into the open-path rework (slice 5).

## Alternatives considered

- **Option B — single project-first drill-down** (one `sidebarAdaptable` split view: Projects → sessions; Settings in its own window). Simpler and least chrome, but forces a project pick before resuming a recent session — wrong for the resume-heavy headset persona. Rejected; its Recents idea is folded into Option A's Workspaces tab.
- **Keep the desktop-sidebar port.** Rejected — it's the thing dogfooding flagged; it's an iPad/Mac pattern, not visionOS.
- **More than three tabs** (e.g. surfacing Automations/Tasks now). Deferred — those are inert until wired; tabs are for a small fixed set, so they live as sidebar items/future tabs, not nav clutter.
