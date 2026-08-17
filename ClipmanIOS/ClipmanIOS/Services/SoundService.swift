import AVFoundation
import Foundation
import UIKit

@MainActor
final class SoundService {
    private var players: [String: AVAudioPlayer] = [:]
    private var audioSessionConfigured = false

    func play(_ name: String, soundsEnabled: Bool, hapticsEnabled: Bool) {
        if soundsEnabled {
            playSound(name)
        }
        if hapticsEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(name == "skip" ? .warning : .success)
        }
    }

    private func playSound(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "wav") else {
            return
        }
        do {
            guard configureAudioSession() else { return }
            if let existing = players[name], existing.isPlaying {
                existing.stop()
                existing.currentTime = 0
                existing.play()
                return
            }
            let player = try AVAudioPlayer(contentsOf: url)
            players[name] = player
            player.play()
        } catch {
            return
        }
    }

    @discardableResult
    func configureAudioSession() -> Bool {
        if audioSessionConfigured { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionConfigured = true
            return true
        } catch {
            return false
        }
    }
}
