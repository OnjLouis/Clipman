import UIKit
import UniformTypeIdentifiers
import os

final class ShareViewController: UIViewController {
    private enum SharedItem {
        case url(NSItemProvider)
        case html(NSItemProvider)
        case text(NSItemProvider, typeIdentifier: String)
        case image(NSItemProvider)

        var noun: String {
            switch self {
            case .url: return "link"
            case .html, .text: return "text"
            case .image: return "photo"
            }
        }
    }

    private struct SharedText {
        let text: String
        let html: String
    }

    private enum QueuedItem: Sendable {
        case text(PendingSharedText)
        case image(PendingSharedImage)
    }

    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var isAdding = false
    private var hasStarted = false
    private let logger = Logger(subsystem: "me.onj.clipman.ios.share", category: "ShareImport")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 360, height: 220)

        let titleLabel = UILabel()
        titleLabel.text = "Share to Clipman"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header

        let noun = sharedItem()?.noun ?? "item"
        statusLabel.text = "Preparing \(noun) for Clipman."
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0

        retryButton.configuration = .filled()
        retryButton.configuration?.title = "Try Again"
        retryButton.addTarget(self, action: #selector(addSharedItem), for: .touchUpInside)
        retryButton.isHidden = true

        cancelButton.configuration = .plain()
        cancelButton.configuration?.title = "Cancel"
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, retryButton])
        buttons.axis = .horizontal
        buttons.alignment = .fill
        buttons.distribution = .fillEqually
        buttons.spacing = 12

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.bottomAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        addSharedItem()
    }

    @objc private func addSharedItem() {
        guard !isAdding else { return }
        guard let item = sharedItem() else {
            showFailure("The shared item does not contain one readable photo, link, or text item.")
            return
        }
        isAdding = true
        retryButton.isHidden = true
        retryButton.isEnabled = false
        cancelButton.isEnabled = false
        statusLabel.text = "Preparing \(item.noun) for Clipman."
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let queued = try await enqueue(item)
                logger.notice("Queued one shared \(item.noun, privacy: .public) for Clipman")
                statusLabel.text = "Adding and syncing \(item.noun)."
                UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
                do {
                    let result = try await synchronize(queued)
                    try await remove(queued)
                    statusLabel.text = result == .alreadyExists
                        ? "\(item.noun.capitalized) already exists. Server sync complete."
                        : "\(item.noun.capitalized) added and synced."
                    logger.notice("Synced one shared \(item.noun, privacy: .public)")
                } catch {
                    statusLabel.text = "\(item.noun.capitalized) saved for Clipman. Open Clipman to finish syncing it."
                    logger.notice("Deferred shared \(item.noun, privacy: .public) sync: \(error.localizedDescription, privacy: .public)")
                }
                UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
                try? await Task.sleep(nanoseconds: 700_000_000)
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                logger.error("Could not queue shared item: \(error.localizedDescription, privacy: .public)")
                showFailure(error.localizedDescription)
            }
        }
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: CancellationError())
    }

    private func sharedItem() -> SharedItem? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            return .url(provider)
        }
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.html.identifier)
        }) {
            return .html(provider)
        }
        let textTypes = [UTType.utf8PlainText.identifier, UTType.plainText.identifier, UTType.text.identifier]
        for typeIdentifier in textTypes {
            if let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(typeIdentifier)
            }) {
                return .text(provider, typeIdentifier: typeIdentifier)
            }
        }
        let images = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        return images.count == 1 ? .image(images[0]) : nil
    }

    private func enqueue(_ item: SharedItem) async throws -> QueuedItem {
        switch item {
        case .url(let provider):
            let shared = try await loadText(provider, typeIdentifier: UTType.url.identifier, isHTML: false)
            let store = try PendingSharedTextStore()
            return .text(try store.enqueue(text: shared.text))
        case .html(let provider):
            let shared = try await loadText(provider, typeIdentifier: UTType.html.identifier, isHTML: true)
            let store = try PendingSharedTextStore()
            return .text(try store.enqueue(text: shared.text, html: shared.html))
        case .text(let provider, let typeIdentifier):
            let shared = try await loadText(provider, typeIdentifier: typeIdentifier, isHTML: false)
            let store = try PendingSharedTextStore()
            return .text(try store.enqueue(text: shared.text))
        case .image(let provider):
            return .image(try await enqueueImage(provider))
        }
    }

    private func enqueueImage(_ provider: NSItemProvider) async throws -> PendingSharedImage {
        let suggestedFilename = provider.suggestedName
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<PendingSharedImage, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw PendingSharedImageError.emptyImage }
                    let store = try PendingSharedImageStore()
                    let queued = try store.enqueue(sourceURL: url, suggestedFilename: suggestedFilename)
                    continuation.resume(returning: queued)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func synchronize(_ item: QueuedItem) async throws -> ShareSyncResult {
        let service = ShareSyncService()
        switch item {
        case .text(let text):
            return try await service.synchronize(text: text.text, html: text.html)
        case .image(let image):
            let store = try PendingSharedImageStore()
            let data = try await Task.detached(priority: .userInitiated) {
                try store.readBounded(image)
            }.value
            return try await service.synchronize(
                imageData: data,
                suggestedFilename: image.suggestedFilename
            )
        }
    }

    private func remove(_ item: QueuedItem) async throws {
        try await Task.detached(priority: .utility) {
            switch item {
            case .text(let text):
                try PendingSharedTextStore().remove(text)
            case .image(let image):
                try PendingSharedImageStore().remove(image)
            }
        }.value
    }

    private func loadText(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        isHTML: Bool
    ) async throws -> SharedText {
        let raw = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let item {
                    continuation.resume(returning: Self.stringValue(item))
                } else {
                    continuation.resume(throwing: PendingSharedTextError.emptyText)
                }
            }
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PendingSharedTextError.emptyText
        }
        guard isHTML else { return SharedText(text: raw, html: "") }
        let data = raw.data(using: .utf8) ?? Data()
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let plain = (try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ).string) ?? ""
        return SharedText(text: plain, html: raw)
    }

    nonisolated private static func stringValue(_ value: NSSecureCoding) -> String {
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString ?? "" }
        if let string = value as? String { return string }
        if let string = value as? NSString { return string as String }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let data = value as? Data { return String(data: data, encoding: .utf8) ?? "" }
        return ""
    }

    private func showFailure(_ message: String) {
        isAdding = false
        retryButton.isHidden = false
        retryButton.isEnabled = true
        cancelButton.isEnabled = true
        statusLabel.text = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
