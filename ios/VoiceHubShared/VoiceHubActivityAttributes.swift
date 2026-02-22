import ActivityKit
import Foundation

struct VoiceHubActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var voiceName: String
        var status: VoiceHubStatus
        var lastMessage: String
        var inputMode: String  // "auto", "ptt", "typing"
    }

    var sessionId: String
}

enum VoiceHubStatus: String, Codable, Hashable {
    case ready
    case thinking
    case speaking
    case listening

    var label: String {
        switch self {
        case .ready: "Ready"
        case .thinking: "Thinking..."
        case .speaking: "Speaking..."
        case .listening: "Listening..."
        }
    }

    var dotColorHex: UInt {
        switch self {
        case .ready: 0x2ECC71
        case .thinking: 0xE67E22
        case .speaking: 0x3A86FF
        case .listening: 0xE63946
        }
    }
}
