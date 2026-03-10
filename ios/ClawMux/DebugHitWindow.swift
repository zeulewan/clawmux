import UIKit
import SwiftUI
import os.log

/// Transparent pass-through UIWindow that logs every UIKit hitTest result.
/// Writes to Documents/debug_hits.txt (pullable via devicectl) and os_log.
/// Install via DebugWindowInstaller() in any SwiftUI view body.
final class DebugOverlayWindow: UIWindow {

    static var shared: DebugOverlayWindow?
    private static let log = Logger(subsystem: "com.zeul.clawmux", category: "HitTest")
    private var logURL: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("debug_hits.txt")
    }()

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        isOpaque = false
        windowLevel = UIWindow.Level.normal + 1
        isHidden = false
        // Clear old log on each launch
        if let url = logURL { try? "".write(to: url, atomically: true, encoding: .utf8) }
    }
    required init?(coder: NSCoder) { fatalError() }

    // NOTE: Do NOT override point(inside:) — that prevents hitTest from being called.
    // Returning nil from hitTest passes the touch to the window below.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // event is nil during layout hit-testing — skip those; real touch events are non-nil.
        // Do NOT check for .began phase — hitTest fires before phase is set.
        guard event != nil else { return nil }

        let mainWindow = windowScene?.windows.first(where: { !($0 is DebugOverlayWindow) })
        let hit = mainWindow?.hitTest(point, with: nil)
        let desc = hit.map { viewChain($0) } ?? "nil"
        let line = "TOUCH [\(Int(point.x)),\(Int(point.y))]: \(desc)\n"

        DebugOverlayWindow.log.info("\(line, privacy: .public)")
        if let url = logURL {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
        return nil  // pass through to main window
    }

    private func viewChain(_ v: UIView) -> String {
        var parts: [String] = []
        var cur: UIView? = v
        while let c = cur, parts.count < 8 {
            var name = String(describing: type(of: c))
            if let id = c.accessibilityIdentifier, !id.isEmpty { name += "#\(id)" }
            parts.append(name)
            cur = c.superview
        }
        return parts.joined(separator: " > ")
    }
}

/// Drop `.background(DebugWindowInstaller())` onto any SwiftUI view to activate the overlay.
struct DebugWindowInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            guard DebugOverlayWindow.shared == nil,
                  let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            else { return }
            DebugOverlayWindow.shared = DebugOverlayWindow(windowScene: scene)
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
