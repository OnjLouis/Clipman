import AppKit

final class SoundService {
    enum SoundName: String {
        case copy = "copy.wav"
        case on = "on.wav"
        case off = "off.wav"
        case remote = "remote.wav"
        case skip = "skip.wav"
    }

    private var userSoundsDirectory: URL
    private var currentSound: NSSound?
    var isEnabled = true

    init(applicationSupportURL: URL) {
        userSoundsDirectory = applicationSupportURL.appendingPathComponent("sounds", isDirectory: true)
    }

    func useDataFolder(_ dataFolderURL: URL) {
        userSoundsDirectory = dataFolderURL.appendingPathComponent("sounds", isDirectory: true)
    }

    func play(_ name: SoundName) {
        guard isEnabled else { return }
        currentSound?.stop()
        currentSound = loadSound(name)
        currentSound?.play()
    }

    private func loadSound(_ name: SoundName) -> NSSound? {
        let userURL = userSoundsDirectory.appendingPathComponent(name.rawValue)
        if FileManager.default.fileExists(atPath: userURL.path), let sound = NSSound(contentsOf: userURL, byReference: true) {
            return sound
        }

        guard let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("sounds", isDirectory: true)
            .appendingPathComponent(name.rawValue)
        else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: bundledURL.path) else { return nil }
        return NSSound(contentsOf: bundledURL, byReference: false)
    }
}
