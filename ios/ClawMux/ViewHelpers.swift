import SwiftUI

// MARK: - Voice Color / Icon Tables

let _voiceColorTable: [String: Color] = [
    "af_sky":     Color(hex: 0x3A86FF),
    "af_alloy":   Color(hex: 0xE67E22),
    "af_sarah":   Color(hex: 0xE63946),
    "am_adam":    Color(hex: 0x2ECC71),
    "am_echo":    Color(hex: 0x9B59B6),
    "am_onyx":    Color(hex: 0x7F8C8D),
    "bm_fable":   Color(hex: 0xF1C40F),
    "af_nova":    Color(hex: 0xFF6B9D),
    "am_eric":    Color(hex: 0x00B4D8),
    "af_bella":   Color(hex: 0xFF7043),
    "af_jessica": Color(hex: 0xAB47BC),
    "af_heart":   Color(hex: 0xEC407A),
    "am_michael": Color(hex: 0x26A69A),
    "am_liam":    Color(hex: 0x5C6BC0),
    "am_fenrir":  Color(hex: 0x78909C),
    "bf_emma":    Color(hex: 0xFFA726),
    "bm_george":  Color(hex: 0x66BB6A),
    "bm_daniel":  Color(hex: 0x42A5F5),
    "af_aoede":   Color(hex: 0xCE93D8),
    "af_jadzia":  Color(hex: 0x4DD0E1),
    "af_kore":    Color(hex: 0xA1887F),
    "af_nicole":  Color(hex: 0xF48FB1),
    "af_river":   Color(hex: 0x80CBC4),
    "am_puck":    Color(hex: 0xFFD54F),
    "bf_alice":   Color(hex: 0x90CAF9),
    "bf_lily":    Color(hex: 0xC5E1A5),
    "bm_lewis":   Color(hex: 0xBCAAA4),
]

func voiceColor(_ id: String) -> Color {
    _voiceColorTable[id] ?? Color(hex: 0x8E8E93)
}

func voiceIdByName(_ name: String) -> String {
    ALL_VOICES.first { $0.name.lowercased() == name.lowercased() }?.id ?? name.lowercased()
}

let _voiceIconTable: [String: String] = [
    "af_sky":     "cloud.fill",
    "af_alloy":   "diamond.fill",
    "af_nova":    "star.fill",
    "af_sarah":   "heart.fill",
    "am_adam":    "paperplane.fill",
    "am_echo":    "waveform",
    "am_eric":    "chart.line.uptrend.xyaxis",
    "am_onyx":    "shield.fill",
    "bm_fable":   "book.fill",
    "af_bella":   "info.circle.fill",
    "af_jessica": "checkmark.circle.fill",
    "af_heart":   "heart.fill",
    "am_michael": "shield.lefthalf.filled",
    "am_liam":    "chevron.left.forwardslash.chevron.right",
    "am_fenrir":  "globe",
    "bf_emma":    "envelope.fill",
    "bm_george":  "doc.fill",
    "bm_daniel":  "music.note",
    "af_aoede":   "music.note.list",
    "af_jadzia":  "figure.walk",
    "af_kore":    "target",
    "af_nicole":  "heart.fill",
    "af_river":   "water.waves",
    "am_puck":    "face.smiling.fill",
    "bf_alice":   "bookmark.fill",
    "bf_lily":    "leaf.fill",
    "bm_lewis":   "checklist",
]

func voiceIcon(_ id: String) -> String {
    _voiceIconTable[id] ?? "mic.fill"
}

func usageColor(_ pct: Int) -> Color {
    if pct >= 80 { return .cDanger }
    if pct >= 60 { return .cWarning }
    return .cSuccess
}

// MARK: - Time Formatting

private let _fmtToday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
private let _fmtOther: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f }()

func shortTime(_ date: Date) -> String {
    (Calendar.current.isDateInToday(date) ? _fmtToday : _fmtOther).string(from: date)
}
