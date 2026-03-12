import SwiftUI
import WebKit

// MARK: - Weak Message Handler (prevents retain cycle with WKUserContentController)

private class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        delegate?.userContentController(c, didReceive: m)
    }
}

// MARK: - MathView (UIViewRepresentable — KaTeX rendered in WKWebView)

struct MathView: UIViewRepresentable {
    let expression: String   // LaTeX without delimiters
    let isBlock: Bool
    @Binding var height: CGFloat

    // Cache rendered heights by expression so repeated renders skip WKWebView reload.
    static var heightCache: [String: CGFloat] = [:]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "height")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        // baseURL = app bundle root so relative paths katex/katex.min.{css,js} and
        // katex/fonts/* (referenced by the CSS) all resolve to bundled resources.
        wv.loadHTMLString(buildHTML(), baseURL: Bundle.main.resourceURL)
    }

    private func buildHTML() -> String {
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let textColor = dark ? "#e8e8e8" : "#1a1a1a"
        let justify = isBlock ? "center" : "flex-start"
        let padding = isBlock ? "6px 4px" : "1px 0"
        let katexSize = isBlock ? "1.2em" : "1em"
        let displayMode = isBlock ? "true" : "false"

        // Escape for JS template literal
        let js = expression
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        // KaTeX loaded synchronously from bundled local files (no network).
        // Font URLs in katex.min.css are relative to katex/ so they resolve to
        // katex/fonts/* within the bundle — no CDN needed.
        return """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,shrink-to-fit=no">
        <link rel="stylesheet" href="katex/katex.min.css">
        <script src="katex/katex.min.js"></script>
        <style>
        *{box-sizing:border-box;margin:0;padding:0}
        html,body{background:transparent;width:100%}
        body{display:flex;justify-content:\(justify);align-items:flex-start;
             padding:\(padding);color:\(textColor);overflow-x:auto}
        .katex{font-size:\(katexSize);color:\(textColor)}
        .katex-display{margin:0}
        .katex-error{color:#cc0000;font-family:monospace;font-size:0.85em}
        </style>
        </head><body><div id="m"></div>
        <script>
        try {
            katex.render(`\(js)`, document.getElementById('m'), {
                displayMode: \(displayMode),
                throwOnError: false,
                errorColor: '#cc0000'
            });
        } catch(e) {
            document.getElementById('m').textContent = e.message;
        }
        requestAnimationFrame(function() {
            window.webkit.messageHandlers.height.postMessage(
                Math.ceil(document.body.scrollHeight));
        });
        </script></body></html>
        """
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MathView
        init(_ p: MathView) { parent = p }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard m.name == "height", let raw = m.body as? NSNumber else { return }
            let h = max(CGFloat(raw.intValue), 20)
            MathView.heightCache[parent.expression] = h
            DispatchQueue.main.async { self.parent.height = h }
        }

        // Fallback: if JS message handler doesn't fire, measure after navigation finishes
        func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
            wv.evaluateJavaScript("Math.ceil(document.body.scrollHeight)") { r, _ in
                guard let raw = r as? Int else { return }
                let h = max(CGFloat(raw), 20)
                MathView.heightCache[self.parent.expression] = h
                DispatchQueue.main.async {
                    if self.parent.height < 20 { self.parent.height = h }
                }
            }
        }
    }
}

// MARK: - MathBlockView (SwiftUI wrapper with dynamic height)

struct MathBlockView: View {
    let expression: String
    let isBlock: Bool
    @State private var height: CGFloat = 36

    var body: some View {
        MathView(expression: expression, isBlock: isBlock, height: $height)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .onAppear {
                if let cached = MathView.heightCache[expression] { height = cached }
            }
    }
}
