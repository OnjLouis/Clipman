import AppKit

@MainActor enum KeyboardNavigation {
    static func move(in window: NSWindow, backwards: Bool) -> Bool {
        guard !(window is NSSavePanel), let root = window.contentView else { return false }
        let current = focusedView(in: window)
        var controls: [NSView]
        if window is HistoryWindow, let current {
            // History has a roving section tab and an explicit toolbar/list loop.
            controls = [current]
            var next = current.nextKeyView
            while let view = next, !controls.contains(where: { $0 === view }) {
                controls.append(view)
                next = view.nextKeyView
            }
        } else {
            controls = orderedControls(in: root)
        }
        controls = controls.filter { isAvailable($0) }
        guard !controls.isEmpty else { return false }
        let index = controls.firstIndex { $0 === current }
        let start = index ?? (backwards ? 0 : controls.count - 1)
        let step = backwards ? -1 : 1
        for offset in 1...controls.count {
            let target = controls[(start + step * offset + controls.count) % controls.count]
            if window.makeFirstResponder(target) {
                target.scrollToVisible(target.bounds)
                return true
            }
        }
        return false
    }

    static func focusedView(in window: NSWindow) -> NSView? {
        guard let responder = window.firstResponder as? NSView else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            return editor.delegate as? NSView
        }
        return responder
    }

    static func orderedControls(in view: NSView) -> [NSView] {
        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
        if view is NSButton || view is HotkeyCaptureField || view is NSTableView || view is NSTextView || view is NSSlider || view is NSStepper {
            return [view]
        }
        if let field = view as? NSTextField {
            return field.isEditable || field.isSelectable ? [field] : []
        }
        if let scroll = view as? NSScrollView {
            return scroll.documentView.map { orderedControls(in: $0) } ?? []
        }
        // Follow the visible layout, not NSStackView's insertion order or AppKit's
        // text-fields-only Tab preference. Do not change the user's system setting.
        return view.subviews.sorted { left, right in
            let a = left.convert(left.bounds, to: view)
            let b = right.convert(right.bounds, to: view)
            if abs(a.midY - b.midY) > 1 { return view.isFlipped ? a.midY < b.midY : a.midY > b.midY }
            return a.minX < b.minX
        }.flatMap { orderedControls(in: $0) }
    }

    private static func isAvailable(_ view: NSView) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor else { return false }
        if let control = view as? NSControl, !control.isEnabled { return false }
        if let button = view as? NSButton, button.refusesFirstResponder { return false }
        return view.acceptsFirstResponder
    }
}
