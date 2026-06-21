# Superset for visionOS

Native Apple Vision Pro client for Superset (SwiftUI/RealityKit, ADR-0003). See
`docs/PRD.md`, `docs/adr/`, and `CONTEXT.md` for the spec and domain language.

## Project generation

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` is the source of
truth). The generated `Superset.xcodeproj` is committed so `xcodebuild` works on a
clean checkout, but regenerate it after changing sources or `project.yml`:

```sh
brew install xcodegen   # once
cd apps/visionos
xcodegen generate
```

## Build & run

Compile against the visionOS simulator SDK:

```sh
cd apps/visionos
xcodebuild -project Superset.xcodeproj -target Superset \
  -sdk xrsimulator -configuration Debug -arch arm64 build
```

> The `-target … -sdk xrsimulator` form is used (rather than `-scheme … -destination
> 'platform=visionOS Simulator,…'`) because it builds against the SDK without
> requiring a matching simulator *runtime*. A `-destination` build needs a visionOS
> simulator runtime whose version matches the installed SDK; when the SDK and the
> installed runtime differ (e.g. SDK 26.4 with only the 26.2 runtime present),
> destination resolution fails even though the code compiles. Install the matching
> runtime via Xcode ▸ Settings ▸ Components to use `-destination` / run in the
> simulator.

Open `Superset.xcodeproj` in Xcode to run on the simulator or a device. Real-device
builds need a signing team (the committed config builds the simulator unsigned).

## M0 — renderer seam

The M0 deliverable is the **presentation-agnostic core + renderer seam**:

- `Sources/Domain` — `WorkspaceStore` (`@Observable`, no SwiftUI), `Workspace`,
  `WorkspaceStatus`. The single source of truth.
- `Sources/Renderer` — `PaneKind`, the `WorkspaceAdapter` protocol, and
  `AdapterRegistry`. An adapter renders the store for a pane kind; the registry
  swaps the active adapter at runtime.
- `Sources/UI` — the SwiftUI views, including the production list and the throwaway
  `DebugDumpView`.

Two adapters drive the **same unmodified store**: `NativeWorkspaceAdapter` (the V1
2D list) and `DebugListAdapter` (a throwaway text dump). The bottom ornament flips
between them at runtime with zero domain change — this proves the seam (PRD §17, M0).
