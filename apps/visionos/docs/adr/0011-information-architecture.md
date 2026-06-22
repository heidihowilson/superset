# 0011 — visionOS information architecture: icon rail + collapsible project tree

**Status:** accepted (V1.1 — supersedes the V1 desktop-sidebar port)

App navigation is a **leading-ornament icon rail** that mirrors the desktop left nav — **⬡ Org · ▣ Workspaces · ◷ Automations · ▤ Tasks & PRs · ＋ New Workspace** — rendered **icons-only by default**, with the label revealed on hover/gaze (`.help()` + hover effect). **Workspaces** (the default) shows a **collapsible project→workspace tree**: a `DisclosureGroup` per project with its workspaces beneath, **grouped by project only (no status grouping)**, foldable so the list stays short, **tap a workspace → its own window**. **Projects is not a rail item** — it's the grouping inside Workspaces. **Settings** is reached from the **Org menu** and opens as its own **2-column `NavigationSplitView`** master/detail (category sidebar + detail pane, the macOS-Ventura/visionOS pattern), replacing the single ~10-section `Form`. Window-per-workspace is unchanged. Full spec: [`../information-architecture.md`](../information-architecture.md).

We chose this because the V1 build transcribed the **desktop sidebar** as a fixed 260×520 ornament with **full-word** nav rows and an **always-expanded** nested project→workspace scroll (duplicated by the main window), plus a **flat Settings `Form`** — all of which read as iPad/Mac on device. The rail keeps the desktop's *information hierarchy* (which Seth wants mirrored) while fixing the visionOS faults: nav becomes a ~1-icon-wide ornament (not a wide panel), full words become icons-with-hover-labels, and the nested list becomes **collapsible** (fold away projects you're not in) — which is what makes a project→session tree workable on a headset.

## Consequences

- Fixes the dogfood complaints: over-wide full-word nav → icons-only rail; always-expanded nested scroll → foldable-per-project tree; flat Settings → master/detail.
- Keeps the desktop mental model (Org / Workspaces / Automations / Tasks & PRs / New) so the two clients feel like one product, but icon-first and collapsible per visionOS.
- Requires rebuilding the nav shell (`WorkspaceSwitcherView` → icon-rail `RootRailView`), the Workspaces pane (`WorkspaceListView` → collapsible `DisclosureGroup` tree), the Org menu (switch-org + Settings + Sign out), and `SettingsView` → split view — sliced into 5 PRs (see spec).
- The **"sessions won't open"** bug is folded into the open-path rework (slice 5).

## Alternatives considered

- **3-tab `sidebarAdaptable` TabView (Workspaces/Projects/Settings) with search-first split views** — the first revision proposal. Rejected in favor of mirroring the desktop rail (Org/Workspaces/Automations/Tasks & PRs) so the clients feel unified, and using a *collapsible* tree rather than splitting Projects into its own tab. Search is retained as an optional filter on the tree, not the primary structure.
- **Status grouping (Recents/Active/All)** inside Workspaces. Rejected — group by **project only**; status is a per-row indicator, not a section.
- **Keep the V1 desktop-sidebar port** (full words, always-expanded, 260pt). Rejected — exactly what dogfooding flagged.
- **Surfacing Automations/Tasks panes now.** They're rail items but inert placeholders until wired.
