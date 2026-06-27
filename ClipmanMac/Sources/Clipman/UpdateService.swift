import AppKit
import Foundation

@MainActor
final class UpdateService {
    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubAsset]
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browser_download_url: String
    }

    private struct UpdateCandidate {
        let version: String
        let releaseURL: URL
        let downloadURL: URL
        let assetName: String
    }

    private let releasesURL = URL(string: "https://api.github.com/repos/OnjLouis/Clipman/releases?per_page=20")!

    func check(currentVersion: String, manual: Bool, installSilently: Bool) {
        let request = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    if manual { self.showError("Could Not Check for Updates", error.localizedDescription) }
                    return
                }
                guard let data,
                      let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data),
                      let candidate = self.bestUpdate(in: releases, currentVersion: currentVersion)
                else {
                    if manual { self.showNoUpdate(currentVersion: currentVersion) }
                    return
                }

                if installSilently {
                    self.downloadAndInstall(candidate)
                } else if manual {
                    self.promptForUpdate(candidate)
                } else {
                    self.showUpdateAvailable(candidate)
                }
            }
        }.resume()
    }

    func openVersionHistory() {
        if let url = URL(string: "https://github.com/OnjLouis/Clipman/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    private func bestUpdate(in releases: [GitHubRelease], currentVersion: String) -> UpdateCandidate? {
        releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release -> UpdateCandidate? in
                let version = normalizedVersion(release.tag_name)
                guard isVersion(version, newerThan: currentVersion),
                      let asset = release.assets.first(where: { isMacAsset($0.name) }),
                      let releaseURL = URL(string: release.html_url),
                      let downloadURL = URL(string: asset.browser_download_url)
                else { return nil }
                return UpdateCandidate(version: version, releaseURL: releaseURL, downloadURL: downloadURL, assetName: asset.name)
            }
            .sorted { versionParts($0.version).lexicographicallyPrecedes(versionParts($1.version)) == false }
            .first
    }

    private func promptForUpdate(_ candidate: UpdateCandidate) {
        let alert = NSAlert()
        alert.messageText = "Clipman \(candidate.version) Is Available"
        alert.informativeText = "Download and install \(candidate.assetName), then relaunch Clipman?"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Version History")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            downloadAndInstall(candidate)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(candidate.releaseURL)
        default:
            break
        }
    }

    private func showUpdateAvailable(_ candidate: UpdateCandidate) {
        let alert = NSAlert()
        alert.messageText = "Clipman \(candidate.version) Is Available"
        alert.informativeText = "Open Version History to download it, or enable silent installs in Preferences."
        alert.addButton(withTitle: "Version History")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(candidate.releaseURL)
        }
    }

    private func showNoUpdate(currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Clipman Is Up to Date"
        alert.informativeText = "Installed version: \(currentVersion)"
        alert.runModal()
    }

    private func downloadAndInstall(_ candidate: UpdateCandidate) {
        let request = URLRequest(url: candidate.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        URLSession.shared.downloadTask(with: request) { [weak self] location, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.showError("Could Not Download Update", error.localizedDescription)
                    return
                }
                guard let location else {
                    self.showError("Could Not Download Update", "The download did not produce a file.")
                    return
                }
                do {
                    try self.stageAndInstall(zipURL: location, version: candidate.version)
                } catch {
                    self.showError("Could Not Install Update", error.localizedDescription)
                }
            }
        }.resume()
    }

    private func stageAndInstall(zipURL: URL, version: String) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("ClipmanMacUpdate-\(UUID().uuidString)", isDirectory: true)
        let extract = staging.appendingPathComponent("extract", isDirectory: true)
        try fileManager.createDirectory(at: extract, withIntermediateDirectories: true)

        let copiedZip = staging.appendingPathComponent("ClipmanMac-\(version).zip")
        if fileManager.fileExists(atPath: copiedZip.path) {
            try fileManager.removeItem(at: copiedZip)
        }
        try fileManager.copyItem(at: zipURL, to: copiedZip)
        try run("/usr/bin/ditto", arguments: ["-x", "-k", copiedZip.path, extract.path])

        let stagedApp = findClipmanApp(in: extract)
        guard let stagedApp else {
            throw NSError(domain: "ClipmanUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "The update ZIP did not contain Clipman.app."])
        }

        let targetApp = Bundle.main.bundleURL.path.hasPrefix("/Applications/")
            ? Bundle.main.bundleURL
            : URL(fileURLWithPath: "/Applications/Clipman.app")
        let scriptURL = staging.appendingPathComponent("install-clipman-update.zsh")
        let script = """
        #!/bin/zsh
        set -euo pipefail
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do
          sleep 0.2
        done
        rm -rf \(shellQuote(targetApp.path))
        /bin/cp -R \(shellQuote(stagedApp.path)) \(shellQuote(targetApp.path))
        /usr/bin/codesign --force --sign - \(shellQuote(targetApp.path)) >/tmp/clipmanmac-update-codesign.log 2>&1 || true
        /usr/bin/open \(shellQuote(targetApp.path))
        rm -rf \(shellQuote(staging.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private func findClipmanApp(in folder: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == "Clipman.app" {
            return url
        }
        return nil
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ClipmanUpdate", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(executable) failed with exit code \(process.terminationStatus)."])
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func isMacAsset(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".zip") && lower.contains("clipmanmac")
    }

    private func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = versionParts(candidate)
        let right = versionParts(current)
        for index in 0..<max(left.count, right.count) {
            let candidatePart = index < left.count ? left[index] : 0
            let currentPart = index < right.count ? right[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    private func versionParts(_ version: String) -> [Int] {
        version
            .split { !$0.isNumber }
            .map { Int($0) ?? 0 }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
