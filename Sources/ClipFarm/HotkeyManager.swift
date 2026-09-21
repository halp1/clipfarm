import AppKit
import Carbon.HIToolbox

/// Registers the global shortcut with Carbon.
///
/// `RegisterEventHotKey` fires no matter which app is in front and asks for no
/// accessibility permission, which matters because the point is to catch the key while
/// a game has focus.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onTrigger: (() -> Void)?
    private let signature: OSType = 0x434C_5046  // 'CLPF'

    private init() {}

    /// Starts listening and calls `handler` on the main queue each time the key fires.
    func start(handler: @escaping () -> Void) {
        onTrigger = handler
        installEventHandler()
        register(Preferences.shared.hotkey)
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
                DispatchQueue.main.async { manager.onTrigger?() }
                return noErr
            },
            1,
            &spec,
            context,
            &eventHandler
        )
    }

    /// Swaps in a new combination. Any previous registration is dropped first.
    func register(_ hotkey: Hotkey) {
        unregister()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
            Log.info("Listening for \(hotkey.displayString)")
        } else {
            // Another app already owns the combination, or the modifiers are empty.
            Log.error("Could not register \(hotkey.displayString), error \(status)")
            NotificationCenter.default.post(name: HotkeyManager.registrationFailed, object: hotkey)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    static let registrationFailed = Notification.Name("ClipFarmHotkeyRegistrationFailed")
}
