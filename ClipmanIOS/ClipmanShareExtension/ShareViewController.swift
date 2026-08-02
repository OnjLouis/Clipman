import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let addButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var isAdding = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 360, height: 220)

        let titleLabel = UILabel()
        titleLabel.text = "Share to Clipman"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header

        statusLabel.text = "Add this photo to Clipman's Rich Text history. Clipman will validate and sync it after you next open the app."
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0

        addButton.configuration = .filled()
        addButton.configuration?.title = "Add to Clipman"
        addButton.addTarget(self, action: #selector(addPhoto), for: .touchUpInside)

        cancelButton.configuration = .plain()
        cancelButton.configuration?.title = "Cancel"
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, addButton])
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

    @objc private func addPhoto() {
        guard !isAdding else { return }
        guard let provider = imageProvider() else {
            showFailure("The shared item does not contain one readable photo.")
            return
        }
        isAdding = true
        addButton.isEnabled = false
        cancelButton.isEnabled = false
        statusLabel.text = "Preparing photo for Clipman."
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await enqueue(provider)
                statusLabel.text = "Photo ready for Clipman. Open Clipman to add and sync it."
                UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
                try? await Task.sleep(nanoseconds: 900_000_000)
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                showFailure(error.localizedDescription)
            }
        }
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: CancellationError())
    }

    private func imageProvider() -> NSItemProvider? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        return providers.count == 1 ? providers[0] : nil
    }

    private func enqueue(_ provider: NSItemProvider) async throws {
        let suggestedFilename = provider.suggestedName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw PendingSharedImageError.emptyImage }
                    let store = try PendingSharedImageStore()
                    _ = try store.enqueue(sourceURL: url, suggestedFilename: suggestedFilename)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func showFailure(_ message: String) {
        isAdding = false
        addButton.isEnabled = true
        cancelButton.isEnabled = true
        statusLabel.text = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
