import AppKit
import ClipmanCore

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let captured = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        }.filter { !$0.isEmpty }
        return PasteboardSnapshot(items: captured)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let pasteboardItems = items.map { itemValues in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in itemValues {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(pasteboardItems)
    }
}

@MainActor
protocol ClipboardMonitorDelegate: AnyObject {
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture text: String, richText: RichTextPayload?, sourceApplication: String, deliberate: Bool)
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCaptureFiles files: [String], formats: [String], containsText: Bool, deliberate: Bool)
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCaptureAdditionalImage text: String, richText: RichTextPayload, sourceApplication: String)
    func clipboardMonitor(_ monitor: ClipboardMonitor, didRejectImage reason: String, deliberate: Bool)
    func clipboardMonitorDidSkipIgnoredApplication(_ monitor: ClipboardMonitor)
}

@MainActor
final class ClipboardMonitor: @unchecked Sendable {
    private struct SuppressedText {
        let text: String
        let expires: Date
    }

    weak var delegate: ClipboardMonitorDelegate?
    var isEnabled = true
    var ignoredApplications: [String] = []
    var includeImagesInRichTextHistory = false
    var alsoAddCopiedImageFilesToRichTextHistory = false
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var embeddedImagePasteboardFile: EmbeddedImagePasteboardFile?
    private var ignoredChangeCount: Int?
    private var suppressedRemoteTexts: [SuppressedText] = []
    private var lastClipboardDiagnostic = "No clipboard changes have been inspected in this Clipman session."

    init() {
        EmbeddedImagePasteboardFile.removeStaleFiles()
    }

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
        capture(from: pasteboard, playSkipSound: false, deliberate: false)
    }

    func saveCurrentContents() {
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        ignoredChangeCount = nil
        capture(from: pasteboard, playSkipSound: true, deliberate: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func writeInternalText(
        _ text: String,
        richText: RichTextPayload? = nil,
        imageFilename: String? = nil
    ) {
        suppressRemoteEchoText(text)
        let pasteboard = NSPasteboard.general
        embeddedImagePasteboardFile = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        embeddedImagePasteboardFile = RichTextData.write(
            richText,
            to: pasteboard,
            imageFilename: imageFilename
        )
        ignoredChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
    }

    func writeTemporaryInternalText(
        _ text: String,
        richText: RichTextPayload? = nil,
        imageFilename: String? = nil,
        restoreAfter delay: TimeInterval,
        action: () -> Void
    ) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let previousImagePasteboardFile = embeddedImagePasteboardFile
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let promise = RichTextData.write(
            richText,
            to: pasteboard,
            imageFilename: imageFilename
        )
        embeddedImagePasteboardFile = promise
        ignoredChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            snapshot.restore(to: pasteboard)
            if self.embeddedImagePasteboardFile === promise {
                self.embeddedImagePasteboardFile = previousImagePasteboardFile
            }
            self.ignoredChangeCount = pasteboard.changeCount
            self.lastChangeCount = pasteboard.changeCount
        }
    }

    func writeInternalFiles(_ paths: [String], includeText: Bool = true) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let pasteboard = NSPasteboard.general
        embeddedImagePasteboardFile = nil
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        if includeText {
            pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        }
        ignoredChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
    }

    func suppressRemoteEchoText(_ text: String, for seconds: TimeInterval = 60) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let now = Date()
        suppressedRemoteTexts.removeAll { $0.expires <= now || $0.text == text }
        suppressedRemoteTexts.append(SuppressedText(text: text, expires: now.addingTimeInterval(seconds)))
    }

    func diagnosticsReport() -> String {
        lastClipboardDiagnostic
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
        embeddedImagePasteboardFile = nil
        capture(from: pasteboard, playSkipSound: true, deliberate: false)
    }

    private func capture(from pasteboard: NSPasteboard, playSkipSound: Bool, deliberate: Bool) {
        guard isEnabled || deliberate else { return }
        let appDiagnostic = foregroundApplicationDiagnostic()
        let pasteboardDiagnostic = pasteboardTypesDiagnostic(from: pasteboard)
        if !deliberate && isClipmanForegroundApplication() {
            lastClipboardDiagnostic = clipboardDiagnostic(
                result: "Skipped because Clipman itself was the foreground application.",
                appDiagnostic: appDiagnostic,
                pasteboardDiagnostic: pasteboardDiagnostic
            )
            if playSkipSound {
                delegate?.clipboardMonitorDidSkipIgnoredApplication(self)
            }
            return
        }
        guard deliberate || !isIgnoredForegroundApplication() else {
            lastClipboardDiagnostic = clipboardDiagnostic(
                result: "Skipped because the foreground application matched the ignored-applications list.",
                appDiagnostic: appDiagnostic,
                pasteboardDiagnostic: pasteboardDiagnostic
            )
            if playSkipSound {
                delegate?.clipboardMonitorDidSkipIgnoredApplication(self)
            }
            return
        }
        if shouldSkipPasteboardTypes(pasteboard, includeIgnoredApplications: !deliberate) {
            lastClipboardDiagnostic = clipboardDiagnostic(
                result: "Skipped because pasteboard types indicate concealed or ignored-application data.",
                appDiagnostic: appDiagnostic,
                pasteboardDiagnostic: pasteboardDiagnostic
            )
            if playSkipSound {
                delegate?.clipboardMonitorDidSkipIgnoredApplication(self)
            }
            return
        }
        if let fileCapture = fileCapture(from: pasteboard) {
            lastClipboardDiagnostic = clipboardDiagnostic(
                result: "Captured file or non-text clipboard event. File count: \(fileCapture.files.count).",
                appDiagnostic: appDiagnostic,
                pasteboardDiagnostic: pasteboardDiagnostic
            )
            delegate?.clipboardMonitor(self, didCaptureFiles: fileCapture.files, formats: fileCapture.formats, containsText: pasteboard.string(forType: .string) != nil, deliberate: deliberate)
            captureAdditionalRichTextImageIfEnabled(from: fileCapture.files)
            return
        }
        let text = pasteboard.string(forType: .string)
        let fileReferenceCount = pasteboard.pasteboardItems?.filter {
            $0.types.contains(.fileURL) || $0.types.contains(NSPasteboard.PasteboardType("public.file-url"))
        }.count ?? 0
        if EmbeddedImageFileImport.shouldUsePasteboardImageFallback(
            fileReferenceCount: fileReferenceCount,
            plainText: text,
            automaticCaptureEnabled: alsoAddCopiedImageFilesToRichTextHistory
        ), let imageInput = RichTextData.standaloneImageInput(from: pasteboard, preferredFilename: text) {
            captureStandaloneImage(
                imageInput,
                deliberate: deliberate,
                appDiagnostic: appDiagnostic,
                pasteboardDiagnostic: pasteboardDiagnostic,
                processingDescription: "Processing a copied Finder image for Rich Text history."
            )
            return
        }
        guard let text, !text.isEmpty else {
            if includeImagesInRichTextHistory,
               let imageInput = RichTextData.standaloneImageInput(from: pasteboard) {
                captureStandaloneImage(
                    imageInput,
                    deliberate: deliberate,
                    appDiagnostic: appDiagnostic,
                    pasteboardDiagnostic: pasteboardDiagnostic,
                    processingDescription: "Processing a standalone image for Rich Text history."
                )
                return
            }
            lastClipboardDiagnostic = clipboardDiagnostic(
                result: "Ignored because the clipboard did not contain non-empty plain text or restorable files.",
                appDiagnostic: appDiagnostic,
                pasteboardDiagnostic: pasteboardDiagnostic
            )
            if playSkipSound {
                delegate?.clipboardMonitorDidSkipIgnoredApplication(self)
            }
            return
        }
        if !deliberate && shouldSuppressRemoteEcho(text) {
            lastClipboardDiagnostic = clipboardDiagnostic(
                result: "Skipped because this text matches a recently auto-copied remote entry.",
                appDiagnostic: appDiagnostic,
                pasteboardDiagnostic: pasteboardDiagnostic
            )
            return
        }
        lastClipboardDiagnostic = clipboardDiagnostic(
            result: "Captured text clipboard event. Text length: \(text.count) characters.",
            appDiagnostic: appDiagnostic,
            pasteboardDiagnostic: pasteboardDiagnostic
        )
        delegate?.clipboardMonitor(self, didCapture: text, richText: RichTextData.capture(from: pasteboard), sourceApplication: sourceApplicationName(), deliberate: deliberate)
    }

    private func captureStandaloneImage(
        _ imageInput: Result<StandaloneImageInput, EmbeddedImageError>,
        deliberate: Bool,
        appDiagnostic: String,
        pasteboardDiagnostic: String,
        processingDescription: String
    ) {
        switch imageInput {
        case .failure(let error):
            let reason = error.localizedDescription
            lastClipboardDiagnostic = clipboardDiagnostic(
                result: "Image was not saved: \(reason)",
                appDiagnostic: appDiagnostic,
                pasteboardDiagnostic: pasteboardDiagnostic
            )
            delegate?.clipboardMonitor(self, didRejectImage: reason, deliberate: deliberate)
        case .success(let input):
            let sourceApplication = sourceApplicationName()
            lastClipboardDiagnostic = clipboardDiagnostic(
                result: processingDescription,
                appDiagnostic: appDiagnostic,
                pasteboardDiagnostic: pasteboardDiagnostic
            )
            Task { @MainActor [weak self] in
                do {
                    let prepared = try await Task.detached(priority: .utility) {
                        try EmbeddedImageHTML.makePayload(data: input.data, filename: input.filename)
                    }.value
                    guard let self else { return }
                    self.lastClipboardDiagnostic = self.clipboardDiagnostic(
                        result: "Captured standalone image. Stored size: \(prepared.info.data.count) bytes; dimensions: \(prepared.info.width) by \(prepared.info.height).",
                        appDiagnostic: appDiagnostic,
                        pasteboardDiagnostic: pasteboardDiagnostic
                    )
                    self.delegate?.clipboardMonitor(
                        self,
                        didCapture: prepared.text,
                        richText: prepared.payload,
                        sourceApplication: sourceApplication,
                        deliberate: deliberate
                    )
                } catch {
                    guard let self else { return }
                    let reason = error.localizedDescription
                    self.lastClipboardDiagnostic = self.clipboardDiagnostic(
                        result: "Image was not saved: \(reason)",
                        appDiagnostic: appDiagnostic,
                        pasteboardDiagnostic: pasteboardDiagnostic
                    )
                    self.delegate?.clipboardMonitor(self, didRejectImage: reason, deliberate: deliberate)
                }
            }
        }
    }

    private func captureAdditionalRichTextImageIfEnabled(from paths: [String]) {
        guard alsoAddCopiedImageFilesToRichTextHistory,
              paths.count == 1,
              ["png", "jpg", "jpeg"].contains(URL(fileURLWithPath: paths[0]).pathExtension.lowercased())
        else {
            return
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let sourceApplication = sourceApplicationName()
        Task { @MainActor [weak self] in
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    try EmbeddedImageFileImport.prepare(urls: urls)
                }.value
                guard let self else { return }
                self.delegate?.clipboardMonitor(
                    self,
                    didCaptureAdditionalImage: prepared.text,
                    richText: prepared.payload,
                    sourceApplication: sourceApplication
                )
            } catch {
                guard let self else { return }
                self.lastClipboardDiagnostic += "\nAdditional Rich Text image: not added (\(error.localizedDescription))"
            }
        }
    }

    private func shouldSuppressRemoteEcho(_ text: String) -> Bool {
        let now = Date()
        suppressedRemoteTexts.removeAll { $0.expires <= now }
        return suppressedRemoteTexts.contains { $0.text == text }
    }

    private func clipboardDiagnostic(result: String, appDiagnostic: String, pasteboardDiagnostic: String) -> String {
        [
            "Last clipboard inspection",
            "Result: \(result)",
            appDiagnostic,
            pasteboardDiagnostic
        ].joined(separator: "\n")
    }

    private func foregroundApplicationDiagnostic() -> String {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != NSRunningApplication.current.processIdentifier
        else {
            return "Foreground application: none reported, or Clipman itself."
        }

        let lines = [
            "Foreground application:",
            "  Name: \(application.localizedName ?? "")",
            "  Bundle identifier: \(application.bundleIdentifier ?? "")",
            "  Process identifier: \(application.processIdentifier)",
            "  Executable: \(application.executableURL?.path ?? "")",
            "  Bundle: \(application.bundleURL?.path ?? "")",
            "  Ignore candidates: \(ignoredApplicationCandidates(for: application).joined(separator: ", "))"
        ]
        return lines.joined(separator: "\n")
    }

    private func ignoredApplicationCandidates(for application: NSRunningApplication) -> [String] {
        [
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
            .reduce(into: [String]()) { result, candidate in
                if !result.contains(candidate) {
                    result.append(candidate)
                }
            }
    }

    private func pasteboardTypesDiagnostic(from pasteboard: NSPasteboard) -> String {
        let itemTypes: [String] = pasteboard.pasteboardItems?
            .enumerated()
            .map { index, item in
                let types = item.types.map(\.rawValue).sorted().joined(separator: ", ")
                return "  Item \(index + 1): \(types.isEmpty ? "none" : types)"
            } ?? []
        let directTypes = pasteboard.types?.map(\.rawValue).sorted().joined(separator: ", ") ?? ""
        var lines: [String] = [
            "Pasteboard:",
            "  Change count: \(pasteboard.changeCount)",
            "  Direct types: \(directTypes.isEmpty ? "none" : directTypes)"
        ]
        if itemTypes.isEmpty {
            lines.append("  Items: none")
        } else {
            lines.append(contentsOf: itemTypes)
        }
        return lines.joined(separator: "\n")
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

        let candidates = ignoredApplicationCandidates(for: application)

        return candidates.contains { candidate in
            ignored.contains { ignoredItem in
                ignoredApplicationMatches(ignoredItem: ignoredItem, candidate: candidate)
            }
        }
    }

    private func isClipmanForegroundApplication() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier
    }

    private func shouldSkipPasteboardTypes(_ pasteboard: NSPasteboard, includeIgnoredApplications: Bool = true) -> Bool {
        let types = allPasteboardTypeNames(from: pasteboard)
        if types.contains(where: isConcealedPasteboardType) {
            return true
        }

        guard includeIgnoredApplications else { return false }
        let ignored = ignoredApplications
            .map { normalizeIgnoredApplicationName($0) }
            .filter { !$0.isEmpty }
        guard !ignored.isEmpty else { return false }

        let candidates = types
            .flatMap { pasteboardTypeCandidates($0) }
            .filter { !$0.isEmpty }

        return candidates.contains { candidate in
            ignored.contains { ignoredItem in
                ignoredApplicationMatches(ignoredItem: ignoredItem, candidate: candidate)
            }
        }
    }

    private func ignoredApplicationMatches(ignoredItem: String, candidate: String) -> Bool {
        guard !ignoredItem.isEmpty, !candidate.isEmpty else { return false }
        if ignoredItem == candidate { return true }
        if candidate.hasPrefix("\(ignoredItem).") { return true }
        if candidate.hasPrefix("\(ignoredItem)-") { return true }
        if candidate.hasPrefix("\(ignoredItem)_") { return true }
        if candidate.hasPrefix("\(ignoredItem) ") { return true }
        return false
    }

    private func normalizeIgnoredApplicationName(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(".app") || trimmed.lowercased().hasSuffix(".exe") {
            trimmed = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
        }
        return trimmed.lowercased()
    }

    private func allPasteboardTypeNames(from pasteboard: NSPasteboard) -> [String] {
        var names = pasteboard.types?.map(\.rawValue) ?? []
        for item in pasteboard.pasteboardItems ?? [] {
            names.append(contentsOf: item.types.map(\.rawValue))
        }
        return Array(Set(names.map { $0.lowercased() })).sorted()
    }

    private func isConcealedPasteboardType(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized == "org.nspasteboard.concealedtype"
            || normalized.contains("concealed")
            || normalized.contains("transient")
    }

    private func pasteboardTypeCandidates(_ value: String) -> [String] {
        let normalized = normalizeIgnoredApplicationName(value)
        var candidates = [normalized]
        if normalized == "com.agilebits.onepassword" {
            candidates.append("1password")
            candidates.append("com.1password.1password")
        }
        return Array(Set(candidates))
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
