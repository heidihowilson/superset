# 0009 — Rich transcript content rendered via WKWebView (markdown/syntax/diff)

**Status:** accepted (scoped exception to ADR-0003)

The chat transcript's **rich content — streaming markdown, syntax-highlighted code, and diffs — renders in a WKWebView** reusing the desktop's proven web stack: `streamdown` (streaming markdown), `shiki` (syntax highlighting), and `@pierre/diffs` ("diffs.com", the desktop's diff renderer, wrapped by `LightDiffViewer`). This sits behind the renderer protocol; the native shell, windows, lists, composer, navigation, and chrome remain SwiftUI (ADR-0003). We chose this because these rendering primitives are solved-in-web and extremely costly to rebuild natively in Swift (the largest V1 native risk, R6), the desktop already ships them, and diff/review fidelity is not the client's primary story — so web tech here simplifies without compromising the native interaction model.

## Consequences

- Reuses good rendering *primitives*, not the unusable web *workspace UI* — ADR-0003 still governs all UI/shell/interaction.
- **The webview is a pure renderer fed by native** (markdown/diff strings passed in); it makes **no network calls and needs no auth** — native fetches the chat data over the relay and hands content in. Interactions (tap-to-expand, "open full" host fetch) bridge back to native.
- The content surface must be tuned for the headset: ≥60pt targets, gaze-friendly scroll, glass-compatible theming.
- Dissolves most of R6 (no native markdown/syntax/diff substrate; the Swift-substrate spike is dropped).
- This is the **one** sanctioned web-content surface; everything else stays native.
