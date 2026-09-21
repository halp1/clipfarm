import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that listens for the next key combination and stores it.
///
/// While it is listening the app takes a local event monitor, so the keys go here
/// instead of to the menus.
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var hotkey: Hotkey

    func makeNSView(context: Context) -> HotkeyRecorderButton {
        let button = HotkeyRecorderButton()
        button.hotkey = hotkey
        button.onChange = { hotkey = $0 }
        return button
    }

    func updateNSView(_ nsView: HotkeyRecorderButton, context: Context) {
        nsView.hotkey = hotkey
    }
}

final class HotkeyRecorderButton: NSButton {
    var onChange: ((Hotkey) -> Void)?
    private var monitor: Any?

    var hotkey: Hotkey = .default {
        didSet { refreshTitle() }
    }

    private var isRecording = false {
        didSet { refreshTitle() }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refreshTitle() {
        title = isRecording ? "Press keys…" : hotkey.displayString
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        // Pause the live shortcut so recording ⌘⇧1 does not also cut a clip.
        HotkeyManager.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }

            if event.type == .keyDown {
                if event.keyCode == UInt16(kVK_Escape) {
                    self.stopRecording()
                    return nil
                }
                let modifiers = Hotkey.carbonModifiers(from: event.modifierFlags)
                // A shortcut with no modifier would swallow an ordinary keystroke.
                guard modifiers != 0 else { NSSound.beep(); return nil }
                let candidate = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
                self.hotkey = candidate
                self.onChange?(candidate)
                self.stopRecording()
                return nil
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        HotkeyManager.shared.register(Preferences.shared.hotkey)
    }
}
