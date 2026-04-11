import SwiftUI
import WebKit
import AppKit

/// A WKWebView-backed markdown renderer that understands full GitHub-flavored
/// markdown (headings, code fences, tables, task lists) and LaTeX math via
/// KaTeX. Assets are pulled from jsDelivr at first load; network is already
/// required to reach Claude so this adds no new runtime requirement.
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let isError: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ready")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparent background so the panel's dark backdrop shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        context.coordinator.webView = webView
        webView.loadHTMLString(Self.htmlTemplate, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.setContent(markdown: markdown, isError: isError)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var ready = false
        private var pendingMarkdown: String = ""
        private var pendingIsError: Bool = false
        private var lastRenderedMarkdown: String? = nil
        private var lastRenderedIsError: Bool? = nil

        func setContent(markdown: String, isError: Bool) {
            pendingMarkdown = markdown
            pendingIsError = isError
            flush()
        }

        private func flush() {
            guard ready, let webView else { return }
            if lastRenderedMarkdown == pendingMarkdown && lastRenderedIsError == pendingIsError {
                return
            }
            lastRenderedMarkdown = pendingMarkdown
            lastRenderedIsError = pendingIsError

            // JSON-encode the payload so any quotes/backslashes survive the
            // JS string boundary without escaping bugs.
            let payload: [String: Any] = [
                "text": pendingMarkdown,
                "isError": pendingIsError
            ]
            guard
                let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.render(\(json));", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The `ready` handshake comes from the page itself via the
            // messageHandler — don't render until then, because KaTeX's
            // auto-render.min.js is loaded with `defer` and may not be
            // available at didFinish time.
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "ready" {
                ready = true
                flush()
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // First navigation (loadHTMLString) must proceed. After that,
            // intercept user link clicks and open them in the default browser
            // instead of inside the panel.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    private static let htmlTemplate: String = #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css" crossorigin="anonymous">
<script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js" crossorigin="anonymous"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js" crossorigin="anonymous"></script>
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
<style>
:root { color-scheme: dark; }
html, body {
  margin: 0;
  padding: 0;
  background: transparent;
  color: #ffffff;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  font-size: 14px;
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
  word-wrap: break-word;
}
body {
  padding: 4px 2px 8px;
}
h1, h2, h3, h4, h5, h6 {
  font-weight: 600;
  margin: 0.8em 0 0.35em;
  line-height: 1.3;
}
h1 { font-size: 20px; }
h2 { font-size: 17px; }
h3 { font-size: 15px; }
h4, h5, h6 { font-size: 14px; }
p { margin: 0.5em 0; }
p:first-child, h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
ul, ol { padding-left: 22px; margin: 0.4em 0; }
li { margin: 0.15em 0; }
a { color: #6AB7FF; text-decoration: none; }
a:hover { text-decoration: underline; }
code {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12.5px;
  background: rgba(255, 255, 255, 0.10);
  padding: 1px 5px;
  border-radius: 4px;
}
pre {
  background: rgba(255, 255, 255, 0.06);
  padding: 12px 14px;
  border-radius: 8px;
  overflow-x: auto;
  margin: 0.6em 0;
}
pre code {
  background: transparent;
  padding: 0;
  font-size: 12.5px;
  color: #f0f0f0;
  white-space: pre;
}
blockquote {
  border-left: 3px solid rgba(255, 255, 255, 0.25);
  margin: 0.5em 0;
  padding: 0 14px;
  color: rgba(255, 255, 255, 0.85);
}
hr {
  border: none;
  border-top: 1px solid rgba(255, 255, 255, 0.15);
  margin: 1em 0;
}
table {
  border-collapse: collapse;
  margin: 0.6em 0;
  font-size: 13px;
}
th, td {
  border: 1px solid rgba(255, 255, 255, 0.15);
  padding: 5px 10px;
  text-align: left;
}
th { background: rgba(255, 255, 255, 0.06); }
img { max-width: 100%; }
.katex { color: inherit; font-size: 1em; }
.katex-display { margin: 0.6em 0; overflow-x: auto; overflow-y: hidden; }
#content.error {
  color: rgba(255, 90, 90, 0.95);
  white-space: pre-wrap;
  font-family: -apple-system, BlinkMacSystemFont, sans-serif;
}
::selection { background: rgba(106, 183, 255, 0.35); }
</style>
</head>
<body>
<div id="content"></div>
<script>
(function () {
  let pending = null;

  function scriptsReady() {
    return typeof window.marked !== 'undefined'
      && typeof window.renderMathInElement !== 'undefined';
  }

  function renderNow() {
    if (!pending) return;
    const { text, isError } = pending;
    const el = document.getElementById('content');
    if (isError) {
      el.className = 'error';
      el.textContent = text;
      return;
    }
    el.className = '';
    el.innerHTML = window.marked.parse(text);
    try {
      window.renderMathInElement(el, {
        delimiters: [
          { left: '$$', right: '$$', display: true },
          { left: '\\[', right: '\\]', display: true },
          { left: '$',  right: '$',  display: false },
          { left: '\\(', right: '\\)', display: false }
        ],
        throwOnError: false,
        ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
      });
    } catch (e) {
      // KaTeX failures shouldn't blank the response — we already have the
      // marked-rendered HTML in place.
      console.error('KaTeX error:', e);
    }
  }

  window.render = function (payload) {
    pending = payload;
    if (scriptsReady()) {
      renderNow();
    }
    // else: the poller below will catch it once scripts finish loading
  };

  // Poll briefly for script readiness, then signal Swift.
  const start = Date.now();
  (function waitForScripts() {
    if (scriptsReady()) {
      if (pending) renderNow();
      if (window.webkit && window.webkit.messageHandlers.ready) {
        window.webkit.messageHandlers.ready.postMessage(true);
      }
      return;
    }
    if (Date.now() - start > 5000) {
      // Signal anyway so the user sees *something* — marked may be available
      // even if KaTeX isn't. renderNow() handles the typeof check.
      if (window.webkit && window.webkit.messageHandlers.ready) {
        window.webkit.messageHandlers.ready.postMessage(true);
      }
      return;
    }
    setTimeout(waitForScripts, 30);
  })();
})();
</script>
</body>
</html>
"""#
}
