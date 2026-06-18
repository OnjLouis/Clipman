import Foundation
import Carbon

@MainActor
final class HotkeyManager {
    enum Action: UInt32 {
        case showHistory = 1
        case toggleMonitoring = 2
    }

    var handler: ((Action) -> Void)?
    private var refs: [Action: EventHotKeyRef?] = [:]
    nonisolated(unsafe) private static weak var current: HotkeyManager?

    init() {
        Self.current = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            if let action = Action(rawValue: hotkeyID.id) {
                DispatchQueue.main.async {
                    HotkeyManager.current?.handler?(action)
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    func register(showHistory: HotkeyDescriptor, toggleMonitoring: HotkeyDescriptor) {
        unregisterAll()
        register(showHistory, action: .showHistory)
        for alias in showHistory.layoutFallbacks {
            if alias != showHistory && alias != toggleMonitoring {
                register(alias, action: .showHistory)
            }
        }
        register(toggleMonitoring, action: .toggleMonitoring)
    }

    func unregisterAll() {
        for ref in refs.values {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
    }

    private func register(_ descriptor: HotkeyDescriptor, action: Action) {
        guard descriptor.isValid else { return }
        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: OSType(0x434C504D), id: action.rawValue)
        let status = RegisterEventHotKey(descriptor.keyCode, descriptor.modifiers.carbonFlags, hotkeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs[action] = ref
        }
    }
}
