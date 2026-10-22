import Carbon.HIToolbox
import Observation

/// System-wide shortcuts through Carbon's `RegisterEventHotKey`, which needs no Accessibility permission.
@MainActor
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Names whose shortcut could not be registered, usually because another app owns it.
    private(set) var conflicts: Set<String> = []

    @ObservationIgnored private var entries: [String: (combo: KeyCombo, action: () -> Void)] = [:]
    @ObservationIgnored private var refs: [String: EventHotKeyRef] = [:]
    @ObservationIgnored private var namesByID: [UInt32: String] = [:]
    @ObservationIgnored private var nextID: UInt32 = 1
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var handlerInstalled = false

    nonisolated static let signature: OSType = 0x5052_4348 // "PRCH"

    private init() {}

    /// Registers (or replaces) the shortcut named `name`. Passing `nil` removes it.
    func set(_ name: String, combo: KeyCombo?, action: @escaping () -> Void) {
        unregisterRef(name)
        guard let combo else {
            entries[name] = nil
            conflicts.remove(name)
            return
        }
        entries[name] = (combo, action)
        if !isSuspended { registerRef(name) }
    }

    /// Releases every shortcut while a new one is being recorded, so pressing the current
    /// combination reaches the recorder instead of firing.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for name in refs.keys { unregisterRef(name) }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for name in entries.keys { registerRef(name) }
    }

    // MARK: Carbon

    private func registerRef(_ name: String) {
        guard let entry = entries[name] else { return }
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            entry.combo.keyCode, entry.combo.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            conflicts.insert(name)
            return
        }
        conflicts.remove(name)
        refs[name] = ref
        namesByID[id] = name
    }

    private func unregisterRef(_ name: String) {
        guard let ref = refs.removeValue(forKey: name) else { return }
        UnregisterEventHotKey(ref)
        namesByID = namesByID.filter { $0.value != name }
    }

    fileprivate func fire(id: UInt32) {
        guard let name = namesByID[id] else { return }
        entries[name]?.action()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            // Carbon delivers hot key events on the main run loop.
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: id) }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
