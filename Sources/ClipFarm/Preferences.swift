import AppKit
import Carbon.HIToolbox
import Foundation

/// Where a finished clip gets sent. A clip can go to any combination of these.
enum Destination: String, CaseIterable, Codable {
    case clipboard
    case folder
    case cdn

    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .folder: return "Folder"
        case .cdn: return "HALP/CDN"
        }
    }
}

/// A hotkey as Carbon sees it: a virtual key code plus modifier flags.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Command shift 1.
    static let `default` = Hotkey(
        keyCode: UInt32(kVK_ANSI_1),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// Reads as it would look on the keyboard, like "⌘⇧1".
    var displayString: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Hotkey.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let named = namedKeys[Int(keyCode)] { return named }
        // Ask the current keyboard layout what this key types, so a Dvorak or AZERTY
        // user sees their own letters instead of the QWERTY ones.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2",
        kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    /// Translates the flags on an NSEvent into the Carbon ones a hotkey uses.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

/// Everything the user can change, stored in UserDefaults.
///
/// The CDN key is the one exception. It lives in the keychain, see `KeychainStore`.
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let clipDuration = "clipDuration"
        static let destinations = "destinations"
        static let saveFolder = "saveFolderBookmark"
        static let showMenuBarItem = "showMenuBarItem"
        static let hotkey = "hotkey"
        static let launchAtLogin = "launchAtLogin"
        static let audioSource = "audioSource"
        static let inputDeviceUID = "inputDeviceUID"
        static let outputDeviceUID = "outputDeviceUID"
    }

    /// Posted whenever anything below changes, so the UI and the capture engine can react.
    static let didChange = Notification.Name("ClipFarmPreferencesDidChange")

    /// The shortest and longest clip the duration control allows.
    static let minimumDuration: Double = 1
    static let maximumDuration: Double = 300

    private init() {
        defaults.register(defaults: [
            Key.clipDuration: 30.0,
            Key.showMenuBarItem: true,
            Key.destinations: [Destination.clipboard.rawValue],
            Key.audioSource: AudioSource.output.rawValue
        ])
    }

    private func announce() {
        NotificationCenter.default.post(name: Preferences.didChange, object: nil)
    }

    /// Length of the clip in seconds, clamped to the range the UI offers.
    var clipDuration: Double {
        get {
            let stored = defaults.double(forKey: Key.clipDuration)
            guard stored > 0 else { return 30 }
            return min(max(stored, Preferences.minimumDuration), Preferences.maximumDuration)
        }
        set {
            let clamped = min(max(newValue, Preferences.minimumDuration), Preferences.maximumDuration)
            defaults.set(clamped, forKey: Key.clipDuration)
            announce()
        }
    }

    var destinations: Set<Destination> {
        get {
            let raw = defaults.stringArray(forKey: Key.destinations) ?? []
            return Set(raw.compactMap(Destination.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.destinations)
            announce()
        }
    }

    func isEnabled(_ destination: Destination) -> Bool {
        // The CDN can be switched on in preferences, but without a key it cannot run,
        // so treat it as off until one is saved.
        if destination == .cdn && !KeychainStore.hasAPIKey { return false }
        return destinations.contains(destination)
    }

    /// Reads the stored toggle without the key check, for drawing the checkbox itself.
    func isSelected(_ destination: Destination) -> Bool {
        destinations.contains(destination)
    }

    func setDestination(_ destination: Destination, enabled: Bool) {
        var current = destinations
        if enabled { current.insert(destination) } else { current.remove(destination) }
        destinations = current
    }

    /// The folder clips get copied into, held as a bookmark so the choice survives a
    /// rename or a move.
    var saveFolder: URL? {
        get {
            guard let data = defaults.data(forKey: Key.saveFolder) else { return nil }
            var stale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.saveFolder)
                announce()
                return
            }
            let data = try? newValue.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Key.saveFolder)
            announce()
        }
    }

    var showMenuBarItem: Bool {
        get { defaults.bool(forKey: Key.showMenuBarItem) }
        set { defaults.set(newValue, forKey: Key.showMenuBarItem); announce() }
    }

    /// Which sound gets recorded into a clip.
    var audioSource: AudioSource {
        get {
            guard let raw = defaults.string(forKey: Key.audioSource),
                  let source = AudioSource(rawValue: raw)
            else { return .output }
            return source
        }
        set { defaults.set(newValue.rawValue, forKey: Key.audioSource); announce() }
    }

    /// The input device to record, held by its unique ID so it survives a reconnect.
    /// Empty means whatever macOS has set as the default input.
    var inputDeviceUID: String? {
        get { defaults.string(forKey: Key.inputDeviceUID) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.inputDeviceUID) }
            else { defaults.removeObject(forKey: Key.inputDeviceUID) }
            announce()
        }
    }

    /// The output device whose sound gets recorded, held by its Core Audio UID.
    /// Empty means whatever macOS currently plays through.
    var outputDeviceUID: String? {
        get { defaults.string(forKey: Key.outputDeviceUID) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.outputDeviceUID) }
            else { defaults.removeObject(forKey: Key.outputDeviceUID) }
            announce()
        }
    }

    var hotkey: Hotkey {
        get {
            guard let data = defaults.data(forKey: Key.hotkey),
                  let decoded = try? JSONDecoder().decode(Hotkey.self, from: data)
            else { return .default }
            return decoded
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.hotkey)
            announce()
        }
    }
}
