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

Open `Superset.xcodeproj` in Xcode to run on the simulator or a device.

### Device signing

The target uses **automatic signing** (`CODE_SIGN_STYLE = Automatic`). Signing is
disabled only for the simulator SDK (`CODE_SIGNING_ALLOWED[sdk=xrsimulator*] = NO`),
so the simulator gate builds unsigned while **device builds sign normally**. To
build for / install on hardware, set a development team — either in Xcode (Signing &
Capabilities) or on the command line:

```sh
xcodebuild -project Superset.xcodeproj -target Superset -sdk xros \
  -configuration Debug -arch arm64 \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> -allowProvisioningUpdates build
```

A device build with no team fails with "Signing … requires a development team",
which confirms the signing path is wired (not disabled) and only awaits a team.

## M0 — renderer seam

The M0 deliverable is the **presentation-agnostic core + renderer seam**:

- `Sources/Domain` — `WorkspaceStore` (`@Observable`, no SwiftUI), `Workspace`,
  `WorkspaceStatus`. The single source of truth.
- `Sources/Renderer` — `PaneKind`, the `WorkspaceAdapter` protocol, and
  `AdapterRegistry`. An adapter renders the store for a pane kind; the registry
  resolves the active adapter at runtime.
- `Sources/UI` — the SwiftUI views, including the production list and the
  `DebugDumpView`.

The seam drives the **same unmodified store** through `AdapterRegistry` rather than
rendering it directly: `NativeWorkspaceAdapter` renders the list pane today, and a
future spatial renderer (V2) is an adapter swap with zero domain change — that's
what the seam proves (PRD §17, M0). The Debug surface (`DebugDumpView`) is its own
window rendering the same store directly, for raw-state inspection.
