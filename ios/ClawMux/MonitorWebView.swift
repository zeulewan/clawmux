import SwiftUI
import WebKit

// MARK: - Monitor Web View Sheet

/// Presents a ttyd terminal in a WKWebView.
/// Calls stopMonitor on dismiss so the hub process is cleaned up.
struct MonitorSheet: View {
    let title: String
    let url: String
    let monitorKey: String
    @ObservedObject var vm: ClawMuxViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MonitorWebViewRepresentable(urlString: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            vm.stopMonitor(key: monitorKey)
                            dismiss()
                        }
                    }
                }
        }
    }
}

// MARK: - WKWebView wrapper

private struct MonitorWebViewRepresentable: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> InputCapableWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = InputCapableWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        return webView
    }

    func updateUIView(_ webView: InputCapableWebView, context: Context) {
        guard let url = URL(string: urlString) else { return }
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }
}

// MARK: - WKWebView subclass that accepts keyboard input

private class InputCapableWebView: WKWebView {
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.becomeFirstResponder()
            }
        }
    }
}
