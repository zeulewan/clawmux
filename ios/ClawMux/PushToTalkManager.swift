import Foundation
import PushToTalk
import AVFoundation
import UIKit
import os

private let pttLog = Logger(subsystem: "com.zeul.clawmux", category: "ptt")

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
                pttLog.info("[PTT] Failed to create channel manager: \(error)")
            }
        }
    }

    func joinChannel() {
        guard let manager = channelManager else {
            pttLog.info("[PTT] Channel manager not initialized")
            return
        }

        let descriptor = PTChannelDescriptor(name: "ClawMux", image: nil)
        do {
            try manager.requestJoinChannel(channelUUID: channelUUID, descriptor: descriptor)
            activeChannelUUID = channelUUID
            // Enable Action Button PTT
            manager.setAccessoryButtonEventsEnabled(true, channelUUID: channelUUID) { error in
                if let error {
                    pttLog.info("[PTT] Failed to enable accessory button: \(error)")
                } else {
                    pttLog.info("[PTT] Action Button PTT enabled")
                }
            }
            pttLog.info("[PTT] Joined channel \(channelUUID)")
        } catch {
            pttLog.info("[PTT] Failed to join channel: \(error)")
        }
    }

    func leaveChannel() {
        guard let manager = channelManager, let uuid = activeChannelUUID else { return }
        manager.leaveChannel(channelUUID: uuid)
        activeChannelUUID = nil
        pttLog.info("[PTT] Left channel")
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
                                     didJoinChannel channelUUID: UUID,
                                     reason: PTChannelJoinReason) {
        pttLog.info("[PTT] Joined channel \(channelUUID) reason=\(reason)")
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     didLeaveChannel channelUUID: UUID,
                                     reason: PTChannelLeaveReason) {
        pttLog.info("[PTT] Left channel \(channelUUID) reason=\(reason)")
        Task { @MainActor in
            self.activeChannelUUID = nil
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     didActivate audioSession: AVAudioSession) {
        pttLog.info("[PTT] Audio session activated — begin recording")
        Task { @MainActor in
            self.vm?.audio.startRecording()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     didDeactivate audioSession: AVAudioSession) {
        pttLog.info("[PTT] Audio session deactivated — stop recording")
        Task { @MainActor in
            self.vm?.stopRecording()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     channelUUID: UUID,
                                     didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        pttLog.info("[PTT] Begin transmitting from source=\(source.rawValue)")
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     channelUUID: UUID,
                                     didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        pttLog.info("[PTT] End transmitting from source=\(source.rawValue)")
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                     receivedEphemeralPushToken pushToken: Data) {
        let token = pushToken.map { String(format: "%02x", $0) }.joined()
        pttLog.info("[PTT] Received ephemeral push token: \(token.prefix(16))...")
    }

    nonisolated func incomingPushResult(channelManager: PTChannelManager,
                                         channelUUID: UUID,
                                         pushPayload: [String: Any]) -> PTPushResult {
        // Handle incoming push — leave channel for now (no server pushes yet)
        return PTPushResult.leaveChannel
    }
}

// MARK: - PTChannelRestorationDelegate

extension PushToTalkManager: PTChannelRestorationDelegate {
    nonisolated func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        // Called when the system needs to restore a channel after app relaunch
        PTChannelDescriptor(name: "ClawMux", image: nil)
    }
}
