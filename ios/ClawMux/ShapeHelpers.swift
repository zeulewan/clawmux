import SwiftUI

/// Rect shape extended 1000pt above its bounds so glassEffect's top rim is off-screen.
struct TopOpenRect: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 1000, y: rect.minY - 1000, width: rect.width + 2000, height: rect.height + 1000))
    }
}

/// Frosted glass sheet background: .regularMaterial on iOS 26, canvas1+ultraThinMaterial fallback.
struct SheetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.presentationBackground(.regularMaterial)
        } else {
            content.presentationBackground(content: { Color.canvas1.opacity(0.92).background(.ultraThinMaterial) })
        }
    }
}
