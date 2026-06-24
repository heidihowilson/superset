## Summary

On the visionOS **Simulator**, embedding `TerminalSurfaceView` and attaching any `TerminalIO` (including `LoopbackTerminalIO`) crashes the host app with **`EXC_BREAKPOINT` / SIGTRAP** the moment the surface comes up. Root cause: `GhosttyTerminal.attach(to:)` installs the libghostty `receive_buffer` / `receive_resize` C callbacks and runs their bodies inside `MainActor.assumeIsolated { … }`, but with the `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` backend at least one of those callbacks fires on libghostty's **`termio` IO thread**, not the main run loop. `assumeIsolated` performs a hard `dispatch_assert_queue`, which fails off-main and traps.

This is a runtime isolation bug in the package itself — not in the host. A consumer cannot work around it, because the offending closures are created inside `attach(to:)` and are not overridable from outside `TerminalSurface`.

## Environment

- Package: `TerminalSurface` (staged xcframework build, libghostty `HOST_MANAGED` backend)
- Host: Superset visionOS client (XcodeGen + xcodebuild, Swift 6 language mode, `-strict-concurrency=complete`)
- Simulator: Apple Vision Pro, visionOS 26.2 (also builds against the 26.4 SDK)
- Builds: **green** for both `-sdk xrsimulator` and `-sdk xros`. The crash is runtime-only.

## Repro

1. Embed `TerminalSurfaceView(controller:)` in a SwiftUI `WindowGroup`.
2. In `.onAppear`, `controller.attach(LoopbackTerminalIO(banner: "echo — type here\r\n"))`.
3. Open the window on the visionOS Simulator.
4. The app crashes during surface bring-up (before any keystroke), so the terminal never renders.

## Crash (symbolicated, triggered thread)

```
EXC_BREAKPOINT (SIGTRAP)  code 0x1, 0x1801c1e80

libdispatch.dylib            _dispatch_assert_queue_fail
libdispatch.dylib            dispatch_assert_queue$V2.cold.1
libdispatch.dylib            dispatch_assert_queue
libswift_Concurrency.dylib   _swift_task_checkIsolatedSwift
libswift_Concurrency.dylib   swift_task_isCurrentExecutorWithFlagsImpl(...)
TerminalSurface              static MainActor.assumeIsolated<A>(_:file:line:)
TerminalSurface              closure #2 in GhosttyTerminal.attach(to:)
TerminalSurface              @objc closure #2 in GhosttyTerminal.attach(to:)
libghostty (termio)          termio.Termio.threadEnter      <-- libghostty IO thread, NOT main
libsystem_pthread.dylib      thread_start
```

The bottom frame (`termio.Termio.threadEnter` on a `pthread`) is the proof the callback is invoked off the main actor.

## Where

`Sources/TerminalSurface/GhosttyTerminal.swift`, in `attach(to:)`:

```swift
cfg.receive_buffer = { ud, ptr, len in
    ...
    // Fires on the main run loop (input + draw both run there).
    MainActor.assumeIsolated {            // <-- traps when invoked on the termio thread
        let term = Unmanaged<GhosttyTerminal>.fromOpaque(ud).takeUnretainedValue()
        term.onWrite?(data)
    }
}
cfg.receive_resize = { ud, cols, rows, w, h in
    MainActor.assumeIsolated {            // <-- same hazard
        ...
    }
}
```

The file-level comment (lines 11–14) states the assumption directly: "libghostty's host callbacks (receive_buffer / receive_resize) also fire on main — we assert that with MainActor.assumeIsolated rather than hopping, which would reorder bytes." That assumption does not hold for the `HOST_MANAGED` backend on the Simulator: the engine drives these callbacks from its own `termio` thread.

## Ask

Make the `receive_buffer` / `receive_resize` callbacks safe when libghostty invokes them off the main actor. Some options (your call on the design — the byte-ordering concern in the comment is real):

1. Marshal to the main actor without reordering — e.g. funnel callback bytes through a single serial channel / lock-free queue drained on the main actor, instead of asserting isolation in the C callback.
2. If these callbacks are contractually allowed to fire on the IO thread, do the `onWrite` / `onResize` hop explicitly (`Task { @MainActor in … }` or a `DispatchQueue.main.async`) and document the threading contract for `TerminalIO.send` / `resize` accordingly (today INTEGRATION.md §2 says "send / resize are called on the main actor").
3. At minimum, replace `assumeIsolated` (a hard trap) with a checked hop so an off-main callback degrades gracefully rather than crashing.

## Impact on Superset

This blocks Phase 1 of the Superset terminal integration: the surface cannot render or echo on the Simulator at all. The integration itself is wired and builds green for sim + device; the only blocker is this package-side crash. No host-side workaround exists because the closures are internal to `attach(to:)`.
