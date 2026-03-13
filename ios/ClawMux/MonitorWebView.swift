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

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url = URL(string: urlString) else { return }
        // Only load once
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }
}
