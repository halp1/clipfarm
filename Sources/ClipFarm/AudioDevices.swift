import AVFoundation
import Foundation

/// Which sound goes into a clip.
enum AudioSource: String, CaseIterable, Codable {
    /// What the machine plays: the game, voice chat, music.
    case system
    /// One input device, usually a microphone or an interface.
    case input
    /// Both, summed into a single track.
    case both
    /// A silent clip.
    case none

    var title: String {
        switch self {
        case .system: return "System audio"
        case .input: return "Input device"
        case .both: return "System audio and input"
        case .none: return "No audio"
        }
    }

    var needsInputDevice: Bool { self == .input || self == .both }
    var needsSystemAudio: Bool { self == .system || self == .both }
}

/// Lists the input devices the user can record from.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// Every microphone or audio interface currently attached.
    static func available() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func device(withUID uid: String?) -> AVCaptureDevice? {
        guard let uid else { return nil }
        return available().first(where: { $0.id == uid })
            .flatMap { AVCaptureDevice(uniqueID: $0.id) }
    }

    /// The device to record from: the saved one when it is still plugged in, otherwise
    /// whatever macOS considers the default.
    static func resolvedDevice(preferredUID: String?) -> AVCaptureDevice? {
        if let saved = device(withUID: preferredUID) { return saved }
        return AVCaptureDevice.default(for: .audio)
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
