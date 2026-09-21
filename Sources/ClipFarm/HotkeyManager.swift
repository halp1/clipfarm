import AppKit
import Carbon.HIToolbox

/// Registers the global shortcut with Carbon.
///
/// `RegisterEventHotKey` fires no matter which app is in front and asks for no
/// accessibility permission, which matters because the point is to catch the key while
/// a game has focus.
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// One Carbon registration per shortcut, keyed by the id it was registered with.
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var shortcutIDs: [UInt32: UUID] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    /// Called with the id of whichever shortcut fired.
    private var onTrigger: ((UUID) -> Void)?
    private let signature: OSType = 0x434C_5046  // 'CLPF'

    private init() {}

    /// Starts listening and calls `handler` on the main queue each time a key fires.
    func start(handler: @escaping (UUID) -> Void) {
        onTrigger = handler
        installEventHandler()
        registerAll(Preferences.shared.shortcuts)
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let carbonID = hotKeyID.id
                DispatchQueue.main.async {
                    guard let shortcutID = manager.shortcutIDs[carbonID] else { return }
                    manager.onTrigger?(shortcutID)
                }
                return noErr
            },
            1,
            &spec,
            context,
            &eventHandler
        )
    }

    /// Registers the given shortcuts, replacing whatever was registered before.
    ///
    /// Each one gets its own Carbon id, so the handler can tell which key fired and
    /// therefore how long a clip to save.
    func registerAll(_ shortcuts: [ClipShortcut]) {
        unregister()
        var failed: [ClipShortcut] = []

        for shortcut in shortcuts {
            let carbonID = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.hotkey.keyCode,
                shortcut.hotkey.modifiers,
                EventHotKeyID(signature: signature, id: carbonID),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                registrations[carbonID] = ref
                shortcutIDs[carbonID] = shortcut.id
            } else {
                // Another app already owns the combination, or the modifiers are empty.
                Log.error("Could not register \(shortcut.hotkey.displayString), error \(status)")
                failed.append(shortcut)
            }
        }

        if !registrations.isEmpty {
            let keys = shortcuts.map(\.hotkey.displayString).joined(separator: ", ")
            Log.info("Listening for \(keys)")
        }
        if !failed.isEmpty {
            NotificationCenter.default.post(
                name: HotkeyManager.registrationFailed,
                object: failed
            )
        }
    }

    func unregister() {
        for ref in registrations.values {
            UnregisterEventHotKey(ref)
        }
        registrations.removeAll()
        shortcutIDs.removeAll()
    }

    static let registrationFailed = Notification.Name("ClipFarmHotkeyRegistrationFailed")
}
