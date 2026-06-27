import Foundation
import Carbon

@MainActor
final class HotkeyManager {
    enum Action {
        case showHistory
        case toggleMonitoring
        case quickCopy(entryID: String)
    }

    var handler: ((Action) -> Void)?
    private var refs: [EventHotKeyRef?] = []
    private var actionsByID: [UInt32: Action] = [:]
    nonisolated(unsafe) private static weak var current: HotkeyManager?

    init() {
        Self.current = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            DispatchQueue.main.async {
                guard let manager = HotkeyManager.current,
                      let action = manager.actionsByID[hotkeyID.id]
                else {
                    return
                }
                manager.handler?(action)
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    func register(showHistory: HotkeyDescriptor, toggleMonitoring: HotkeyDescriptor, quickCopies: [String: HotkeyDescriptor]) {
        unregisterAll()
        let reserved = Set(quickCopies.values)
        register(showHistory, action: .showHistory, id: 1)
        for alias in showHistory.layoutFallbacks {
            if alias != showHistory && alias != toggleMonitoring && !reserved.contains(alias) {
                register(alias, action: .showHistory, id: nextAvailableID(startingAt: 10))
            }
        }
        register(toggleMonitoring, action: .toggleMonitoring, id: 2)
        for alias in toggleMonitoring.layoutFallbacks {
            if alias != showHistory && alias != toggleMonitoring && !reserved.contains(alias) {
                register(alias, action: .toggleMonitoring, id: nextAvailableID(startingAt: 20))
            }
        }
        var nextQuickCopyID: UInt32 = 1000
        for (entryID, descriptor) in quickCopies.sorted(by: { $0.key < $1.key }) where descriptor.isValid {
            while actionsByID[nextQuickCopyID] != nil {
                nextQuickCopyID += 1
            }
            register(descriptor, action: .quickCopy(entryID: entryID), id: nextQuickCopyID)
            nextQuickCopyID += 1
        }
    }

    func unregisterAll() {
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        actionsByID.removeAll()
    }

    private func register(_ descriptor: HotkeyDescriptor, action: Action, id: UInt32) {
        guard descriptor.isValid else { return }
        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: OSType(0x434C504D), id: id)
        let status = RegisterEventHotKey(descriptor.keyCode, descriptor.modifiers.carbonFlags, hotkeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
            actionsByID[id] = action
        }
    }

    private func nextAvailableID(startingAt value: UInt32) -> UInt32 {
        var id = value
        while actionsByID[id] != nil {
            id += 1
        }
        return id
    }
}
