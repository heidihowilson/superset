# Superset for visionOS

The native Apple Vision Pro client for Superset — a control surface for watching and directing coding agents across remote workspaces, built to explore spatially organizing work.

## Language

**Workspace**:
An isolated git worktree on a remote host where a coding agent runs. The primary unit a user opens, watches, and organizes in space.
_Avoid_: session (that's a Chat session here), repo

**Window**:
A view onto a Workspace or Project, not the thing itself. A `(sceneKind, domainId)` binding over shared domain state; closing it never kills the remote work.
_Avoid_: tab, screen

**Watch**:
Observing an agent's activity in a Workspace — chat, thinking, tool calls, status — without driving execution. **Host-gated** in V1: chat lives on the Host (Electron IPC / Mastra memory; the cloud Durable Stream is unwired), so watching requires a reachable, awake Host.
_Avoid_: monitor, view

**Chat session**:
A conversation with an agent, scoped to a Workspace. The channel for sending prompts via voice or virtual keyboard.
_Avoid_: thread, conversation

**Project**:
A GitHub-linked repository under an Organization that groups Workspaces.
_Avoid_: repo (a Project is the Superset-side record, not the git repo itself)

**Host**:
A Mac/Linux machine running host-service where Workspaces physically live and agents execute. Reached only via a host-dialed relay tunnel (paid/trial plan only). V1 assumes the Host is awake; when it is unreachable, only the cloud Workspace list is available.
_Avoid_: server, machine, device

**Spatial organization**:
Arranging multiple Workspace surfaces in the user's space to manage parallel agent work — the core value the visionOS client exists to explore.
_Avoid_: layout (layout is the in-window pane tree), tiling
