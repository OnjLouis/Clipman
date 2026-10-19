import SwiftUI
import UIKit

struct QuickClipToolbarButton: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> QuickClipActivationButton {
        let button = QuickClipActivationButton(type: .system)
        button.activate = action
        return button
    }

    func updateUIView(_ button: QuickClipActivationButton, context: Context) {
        button.activate = action
    }
}

final class QuickClipActivationButton: UIButton {
    var activate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setImage(UIImage(systemName: "square.and.pencil"), for: .normal)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Quick Clip"
        accessibilityHint = "Creates a clipboard entry without changing the iOS clipboard."
        addTarget(self, action: #selector(performActivation), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func performActivation() {
        activate?()
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, !isHidden, let activate else { return false }
        // Avoid VoiceOver synthesizing a tap on the history pager behind the toolbar.
        activate()
        return true
    }
}
