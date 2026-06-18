import AppKit

@MainActor
protocol ClipboardMonitorDelegate: AnyObject {
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture text: String)
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCaptureFiles files: [String], formats: [String], containsText: Bool)
}

@MainActor
final class ClipboardMonitor: @unchecked Sendable {
    weak var delegate: ClipboardMonitorDelegate?
    var isEnabled = true
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
        guard isEnabled else { return }
        if let fileCapture = fileCapture(from: pasteboard) {
            delegate?.clipboardMonitor(self, didCaptureFiles: fileCapture.files, formats: fileCapture.formats, containsText: pasteboard.string(forType: .string) != nil)
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        delegate?.clipboardMonitor(self, didCapture: text)
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

    private func pasteboardContainsFiles(_ pasteboard: NSPasteboard) -> Bool {
        let fileTypes = Set([
            NSPasteboard.PasteboardType.fileURL.rawValue,
            "public.file-url",
            "com.apple.pasteboard.promised-file-url",
            "NSFilenamesPboardType"
        ])

        if pasteboard.types?.contains(where: { fileTypes.contains($0.rawValue) }) == true {
            return true
        }

        return pasteboard.pasteboardItems?.contains { item in
            item.types.contains { fileTypes.contains($0.rawValue) }
        } ?? false
    }
}
