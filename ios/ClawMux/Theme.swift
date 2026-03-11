import SwiftUI
import UIKit

// MARK: - Theme (dark-mode-first, used by all views)

enum Theme {
    // These render correctly under forced dark mode
    static let bg            = Color(.systemBackground)
    static let bgSecondary   = Color(.secondarySystemBackground)
    static let textPrimary   = Color(.label)
    static let textSecondary = Color(.secondaryLabel)
    static let textTertiary  = Color(.tertiaryLabel)
    static let blue          = Color(.systemBlue)
    static let green         = Color(.systemGreen)
    static let red           = Color(.systemRed)
    static let orange        = Color(.systemOrange)
    static let yellow        = Color(.systemYellow)
    static let gray          = Color(.systemGray)
    static let gray3         = Color(.systemGray3)
    static let gray5         = Color(.systemGray5)
}

// MARK: - Canvas Colors (dark atmospheric palette)

extension Color {
    static let canvas1     = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0x06090F) : UIColor(hex: 0xF4F6FB) })
    static let canvas2     = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0x0D1117) : UIColor(hex: 0xEDF0F7) })
    static let glass       = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.06) : UIColor.black.withAlphaComponent(0.06) })
    static let glassBright = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.10) })
    static let glassBorder = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.08) })
    static let cText       = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0xEEF2FF) : UIColor(hex: 0x0F172A) })
    static let cTextSec    = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0x94A3B8) : UIColor(hex: 0x3D4F6A) })
    static let cTextTer    = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0x7A8BA3) : UIColor(hex: 0x5A6E88) })
    static let cAccent     = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0x818CF8) : UIColor(hex: 0x007AFF) })
    static let cDanger     = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0xFF453A) : UIColor(hex: 0xFF3B30) })
    static let cSuccess    = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0x30D158) : UIColor(hex: 0x34C759) })
    static let cWarning    = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0xFF9F0A) : UIColor(hex: 0xFF9500) })
    static let cCaution    = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0xFFD60A) : UIColor(hex: 0xFFCC00) })
    static let cCard       = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0x141B26) : UIColor(hex: 0xFFFFFF) })
    static let cBorder     = Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(hex: 0x1E2A3D) : UIColor(hex: 0xD8DDE8) })
}

// MARK: - Color Hex

extension Color {
    init(hex: UInt) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255
        )
    }
}

extension UIColor {
    convenience init(hex: UInt) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
