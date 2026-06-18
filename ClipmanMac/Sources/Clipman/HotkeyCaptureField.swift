import AppKit

@MainActor
protocol HotkeyCaptureFieldDelegate: AnyObject {
    func hotkeyCaptureFieldDidChange(_ field: HotkeyCaptureField)
}

final class HotkeyCaptureField: NSTextField {
    weak var hotkeyDelegate: HotkeyCaptureFieldDelegate?
    private var trackedModifiers: HotkeyDescriptor.Modifiers = []
    var descriptor: HotkeyDescriptor? {
        didSet {
            stringValue = descriptor?.description ?? ""
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        trackedModifiers = HotkeyDescriptor.Modifiers(eventModifierFlags: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        let eventModifiers = HotkeyDescriptor.Modifiers(eventModifierFlags: event.modifierFlags)
        let modifiers = eventModifiers.union(trackedModifiers)
        let keyCode = UInt32(event.keyCode)
        guard !modifiers.isEmpty, HotkeyDescriptor.isAllowedKeyCode(keyCode) else {
            NSSound.beep()
            return
        }
        descriptor = HotkeyDescriptor(keyCode: keyCode, modifiers: modifiers)
        hotkeyDelegate?.hotkeyCaptureFieldDidChange(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyDown(with: event)
        return true
    }
}
