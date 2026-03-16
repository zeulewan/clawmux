import Foundation
import AVFoundation
import UIKit

#if canImport(PushToTalk)
import PushToTalk
#endif

/// Manages the PushToTalk framework integration for walkie-talkie style PTT.
/// Uses PTChannelManager for Action Button hold-to-talk, lock screen PTT, and
/// Dynamic Island waveform indicator.
@MainActor
class PushToTalkManager: NSObject, ObservableObject {
    weak var vm: ClawMuxViewModel?

    private var channelManager: PTChannelManager?
    private var activeChannelUUID: UUID?

    // Channel UUID persisted across launches
    private static let channelUUIDKey = "ptt_channel_uuid"
    private var channelUUID: UUID {
        if let str = UserDefaults.standard.string(forKey: Self.channelUUIDKey),
           let uuid = UUID(uuidString: str) {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: Self.channelUUIDKey)
        return uuid
    }

    func setup() {
        Task {
            do {
                channelManager = try await PTChannelManager.channelManager(delegate: self,
                                                                           restorationDelegate: self)
            } catch {
                print("[PTT] Failed to create channel manager: \(error)")
            }
        }
    }

    func joinChannel() {
        guard let manager = channelManager else {
            print("[PTT] Channel manager not initialized")
            return
        }

        let descriptor = PTChannelDescriptor(name: "ClawMux", image: nil)
        do {
            try manager.requestJoinChannel(channelUUID: channelUUID, descriptor: descriptor)
            activeChannelUUID = channelUUID
            // Enable Action Button PTT
            manager.setAccessoryButtonEventsEnabled(true, channelUUID: channelUUID) { error in
                if let error {
                    print("[PTT] Failed to enable accessory button: \(error)")
                } else {
                    print("[PTT] Action Button PTT enabled")
                }
            }
            print("[PTT] Joined channel \(channelUUID)")
        } catch {
            print("[PTT] Failed to join channel: \(error)")
        }
    }

    func leaveChannel() {
        guard let manager = channelManager, let uuid = activeChannelUUID else { return }
        manager.leaveChannel(channelUUID: uuid)
        activeChannelUUID = nil
        print("[PTT] Left channel")
    }

    /// Called when walking mode activates — join the PTT channel
    func activateForWalkingMode() {
        joinChannel()
    }

    /// Called when walking mode deactivates — leave the PTT channel
    func deactivateForWalkingMode() {
        leaveChannel()
    }
}

// MARK: - PTChannelManagerDelegate

extension PushToTalkManager: PTChannelManagerDelegate {

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     didActivate audioSession: AVAudioSession) {
        // System activated audio for transmission — start recording
        print("[PTT] Audio session activated — begin recording")
        Task { @MainActor in
            self.vm?.audio.startRecording()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     didDeactivate audioSession: AVAudioSession) {
        // System deactivated audio — stop recording and send
        print("[PTT] Audio session deactivated — stop recording")
        Task { @MainActor in
            self.vm?.stopRecording()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     channelUUID: UUID,
                                     didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        print("[PTT] Begin transmitting from: \(source)")
        // source can be .userRequest (in-app), .handsfreeButton (Action Button), .programmaticRequest
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     channelUUID: UUID,
                                     didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        print("[PTT] End transmitting from: \(source)")
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     receivedEphemeralPushToken pushToken: Data) {
        let token = pushToken.map { String(format: "%02x", $0) }.joined()
        print("[PTT] Received ephemeral push token: \(token.prefix(16))...")
        // This token is used for server-initiated transmissions (incoming audio)
        // Store it for the backend to send push notifications to trigger receive
    }

    nonisolated func incomingPushResult(channelManager: PTChannelManager,
                                         channelUUID: UUID) -> PTChannelJoinRequest {
        // Handle incoming push — for now, just accept
        return PTChannelJoinRequest(channelDescriptor: PTChannelDescriptor(name: "ClawMux", image: nil))
    }
}

// MARK: - PTChannelRestorationDelegate

extension PushToTalkManager: PTChannelRestorationDelegate {
    nonisolated func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        // Called when the system needs to restore a channel after app relaunch
        PTChannelDescriptor(name: "ClawMux", image: nil)
    }
}
