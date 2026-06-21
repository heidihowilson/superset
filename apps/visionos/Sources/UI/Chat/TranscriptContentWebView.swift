import SwiftUI
import WebKit

/// The one sanctioned web-content surface (ADR-0009): rich transcript prose renders in
/// a WKWebView reusing the web's rendering model, behind the renderer protocol and
/// **fed by native** — the markdown string is passed in; the webview makes no network
/// calls and needs no auth. Tuned for the headset: transparent so glass shows through,
/// large legible type, and non-scrolling so it self-sizes inside the native list (the
/// native shell owns scroll/gaze).
///
/// V1 ships a compact, dependency-free markdown renderer inside the webview. The
/// desktop's `streamdown`/`shiki`/`@pierre/diffs` bundle is the intended drop-in: it
/// replaces only the HTML/JS template here, since the native↔web contract (pass a
/// string in, post height out) is already the ADR-0009 seam.
struct TranscriptContentWebView: UIViewRepresentable {
    let markdown: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.heightHandler)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // The native list owns scrolling/gaze; the webview self-sizes to its content.
        webView.scrollView.isScrollEnabled = false
        context.coordinator.pendingMarkdown = markdown
        webView.loadHTMLString(Self.template, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(markdown, into: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let heightHandler = "heightChanged"
        private let height: Binding<CGFloat>
        /// Markdown that arrived before the document finished loading; flushed on load.
        var pendingMarkdown: String?
        private var lastRendered: String?
        private weak var webView: WKWebView?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func render(_ markdown: String, into webView: WKWebView) {
            self.webView = webView
            guard lastRendered != markdown else { return }
            lastRendered = markdown
            guard let payload = Self.jsString(markdown) else { return }
            // No reload — re-render in place so a poll update never blanks the surface.
            webView.evaluateJavaScript("window.__render(\(payload));", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let markdown = pendingMarkdown ?? lastRendered ?? ""
            pendingMarkdown = nil
            lastRendered = nil
            render(markdown, into: webView)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.heightHandler else { return }
            let value: CGFloat?
            if let number = message.body as? NSNumber {
                value = CGFloat(number.doubleValue)
            } else {
                value = nil
            }
            guard let value, value.isFinite, value > 0 else { return }
            if abs(height.wrappedValue - value) > 0.5 {
                height.wrappedValue = value
            }
        }

        private static func jsString(_ value: String) -> String? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Self-contained document: glass-friendly CSS + a small markdown→HTML renderer.
    /// `__render` escapes input before formatting (no raw HTML injection), and a
    /// `ResizeObserver` posts the content height back so the native frame tracks it.
    private static let template = """
    <!doctype html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <style>
      :root { color-scheme: light dark; }
      html, body { margin: 0; padding: 0; background: transparent; }
      body {
        font: 30px/1.5 -apple-system, system-ui, sans-serif;
        color: #f5f5f7;
        padding: 4px 2px;
        word-wrap: break-word;
        overflow-wrap: anywhere;
      }
      h1, h2, h3 { line-height: 1.25; margin: 0.4em 0 0.3em; font-weight: 700; }
      h1 { font-size: 1.5em; } h2 { font-size: 1.3em; } h3 { font-size: 1.15em; }
      p { margin: 0.45em 0; }
      ul, ol { margin: 0.45em 0; padding-left: 1.4em; }
      li { margin: 0.2em 0; }
      a { color: #6cb6ff; text-decoration: none; }
      strong { font-weight: 700; }
      em { font-style: italic; }
      code {
        font: 0.92em ui-monospace, SFMono-Regular, Menlo, monospace;
        background: rgba(120,120,128,0.28);
        padding: 0.1em 0.32em;
        border-radius: 6px;
      }
      pre {
        background: rgba(120,120,128,0.22);
        padding: 14px 16px;
        border-radius: 12px;
        overflow-x: auto;
        margin: 0.5em 0;
      }
      pre code { background: none; padding: 0; }
    </style>
    </head>
    <body><div id="root"></div>
    <script>
      function esc(s) {
        return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
      }
      function inline(s) {
        s = esc(s);
        s = s.replace(/`([^`]+)`/g, function(_, c){ return "<code>"+c+"</code>"; });
        s = s.replace(/\\*\\*([^*]+)\\*\\*/g, "<strong>$1</strong>");
        s = s.replace(/(^|[^*])\\*([^*]+)\\*/g, "$1<em>$2</em>");
        s = s.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, function(_, t){ return "<a href=\\"#\\">"+t+"</a>"; });
        return s;
      }
      function toHtml(md) {
        var lines = md.split(/\\r?\\n/);
        var out = [], i = 0;
        while (i < lines.length) {
          var line = lines[i];
          var fence = line.match(/^```(.*)$/);
          if (fence) {
            var buf = []; i++;
            while (i < lines.length && !/^```/.test(lines[i])) { buf.push(lines[i]); i++; }
            i++;
            out.push("<pre><code>" + esc(buf.join("\\n")) + "</code></pre>");
            continue;
          }
          var h = line.match(/^(#{1,3})\\s+(.*)$/);
          if (h) { out.push("<h"+h[1].length+">"+inline(h[2])+"</h"+h[1].length+">"); i++; continue; }
          if (/^\\s*[-*]\\s+/.test(line)) {
            var items = [];
            while (i < lines.length && /^\\s*[-*]\\s+/.test(lines[i])) {
              items.push("<li>"+inline(lines[i].replace(/^\\s*[-*]\\s+/, ""))+"</li>"); i++;
            }
            out.push("<ul>"+items.join("")+"</ul>");
            continue;
          }
          if (/^\\s*\\d+\\.\\s+/.test(line)) {
            var ol = [];
            while (i < lines.length && /^\\s*\\d+\\.\\s+/.test(lines[i])) {
              ol.push("<li>"+inline(lines[i].replace(/^\\s*\\d+\\.\\s+/, ""))+"</li>"); i++;
            }
            out.push("<ol>"+ol.join("")+"</ol>");
            continue;
          }
          if (line.trim() === "") { i++; continue; }
          var para = [line]; i++;
          while (i < lines.length && lines[i].trim() !== "" &&
                 !/^(#{1,3}\\s|```|\\s*[-*]\\s|\\s*\\d+\\.\\s)/.test(lines[i])) {
            para.push(lines[i]); i++;
          }
          out.push("<p>"+para.map(inline).join("<br>")+"</p>");
        }
        return out.join("");
      }
      window.__render = function(md) {
        document.getElementById("root").innerHTML = toHtml(md || "");
        postHeight();
      };
      function postHeight() {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.heightChanged) {
          window.webkit.messageHandlers.heightChanged.postMessage(document.body.scrollHeight);
        }
      }
      new ResizeObserver(postHeight).observe(document.body);
    </script>
    </body>
    </html>
    """
}

/// Self-sizing wrapper: the native list places this, the webview reports its content
/// height, and the frame tracks it so rich prose flows inline with native rows.
struct MarkdownWebText: View {
    let markdown: String
    @State private var height: CGFloat = 0

    var body: some View {
        TranscriptContentWebView(markdown: markdown, height: $height)
            .frame(height: max(height, 24))
            .accessibilityLabel(markdown)
    }
}
