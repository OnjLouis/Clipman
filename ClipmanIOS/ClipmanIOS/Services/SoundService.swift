import AVFoundation
import Foundation
import UIKit

@MainActor
final class SoundService {
    private var players: [String: AVAudioPlayer] = [:]

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
}
