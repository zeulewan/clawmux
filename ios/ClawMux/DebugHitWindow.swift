import UIKit
import SwiftUI
import os.log

/// Transparent pass-through UIWindow that logs every UIKit hitTest result via os_log.
/// Install via DebugWindowInstaller() in any SwiftUI view body.
final class DebugOverlayWindow: UIWindow {

    static var shared: DebugOverlayWindow?
    private static let log = Logger(subsystem: "com.zeul.clawmux", category: "HitTest")

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        isOpaque = false
        windowLevel = UIWindow.Level.normal + 1
        isHidden = false
    }
    required init?(coder: NSCoder) { fatalError() }

    // Pass through all touches — we are only here to observe.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only log touch-began events to avoid spam.
        guard let event,
              event.allTouches?.first?.phase == .began else { return nil }

        // Ask the real window what it would return (nil event = geometric check only).
        let mainWindow = windowScene?.windows.first(where: { !($0 is DebugOverlayWindow) })
        let hit = mainWindow?.hitTest(point, with: nil)
        let desc = hit.map { viewChain($0) } ?? "nil"
        DebugOverlayWindow.log.info("TOUCH [\(Int(point.x)),\(Int(point.y))]: \(desc, privacy: .public)")
        return nil
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
