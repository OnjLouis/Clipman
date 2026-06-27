import AppKit

@MainActor
protocol ClipboardMonitorDelegate: AnyObject {
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture text: String, sourceApplication: String)
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCaptureFiles files: [String], formats: [String], containsText: Bool)
    func clipboardMonitorDidSkipIgnoredApplication(_ monitor: ClipboardMonitor)
}

@MainActor
final class ClipboardMonitor: @unchecked Sendable {
    weak var delegate: ClipboardMonitorDelegate?
    var isEnabled = true
    var ignoredApplications: [String] = []
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ignoredChangeCount: Int?

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func captureCurrentContents() {
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        ignoredChangeCount = nil
        capture(from: pasteboard, playSkipSound: false)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func writeInternalText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ignoredChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
    }

    func writeInternalFiles(_ paths: [String], includeText: Bool = true) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        if includeText {
            pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        }
        ignoredChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if ignoredChangeCount == count {
            ignoredChangeCount = nil
            return
        }
        capture(from: pasteboard, playSkipSound: true)
    }

    private func capture(from pasteboard: NSPasteboard, playSkipSound: Bool) {
        guard isEnabled else { return }
        guard !isIgnoredForegroundApplication() else {
            if playSkipSound {
                delegate?.clipboardMonitorDidSkipIgnoredApplication(self)
            }
            return
        }
        if let fileCapture = fileCapture(from: pasteboard) {
            delegate?.clipboardMonitor(self, didCaptureFiles: fileCapture.files, formats: fileCapture.formats, containsText: pasteboard.string(forType: .string) != nil)
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        delegate?.clipboardMonitor(self, didCapture: text, sourceApplication: sourceApplicationName())
    }

    private func sourceApplicationName() -> String {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return "" }
        return application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func isIgnoredForegroundApplication() -> Bool {
        let ignored = ignoredApplications
            .map { normalizeIgnoredApplicationName($0) }
            .filter { !$0.isEmpty }
        guard !ignored.isEmpty,
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return false }

        let candidates = [
            application.localizedName,
            application.bundleIdentifier,
            application.executableURL?.lastPathComponent,
            application.executableURL?.deletingPathExtension().lastPathComponent,
            application.bundleURL?.lastPathComponent,
            application.bundleURL?.deletingPathExtension().lastPathComponent
        ]
            .compactMap { $0 }
            .map { normalizeIgnoredApplicationName($0) }
            .filter { !$0.isEmpty }

        return candidates.contains { candidate in
            ignored.contains(candidate)
        }
    }

    private func normalizeIgnoredApplicationName(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(".app") || trimmed.lowercased().hasSuffix(".exe") {
            trimmed = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
        }
        return trimmed.lowercased()
    }

    private func fileCapture(from pasteboard: NSPasteboard) -> (files: [String], formats: [String])? {
        let formats = pasteboard.pasteboardItems?
            .flatMap { $0.types.map(\.rawValue) } ?? pasteboard.types?.map(\.rawValue) ?? []
        let files = filePaths(from: pasteboard)
        guard !files.isEmpty else { return nil }
        return (files, Array(Set(formats)).sorted())
    }

    private func filePaths(from pasteboard: NSPasteboard) -> [String] {
        var paths: [String] = []
        let fileURLType = NSPasteboard.PasteboardType.fileURL

        for item in pasteboard.pasteboardItems ?? [] {
            if let value = item.string(forType: fileURLType) ?? item.string(forType: NSPasteboard.PasteboardType("public.file-url")),
               let url = URL(string: value),
               url.isFileURL {
                paths.append(url.path)
            }
        }

        if let propertyList = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            paths.append(contentsOf: propertyList)
        }

        if paths.isEmpty,
           let value = pasteboard.string(forType: fileURLType) ?? pasteboard.string(forType: NSPasteboard.PasteboardType("public.file-url")),
           let url = URL(string: value),
           url.isFileURL {
            paths.append(url.path)
        }

        return Array(Set(paths)).sorted()
    }
}
