import CoreAudio
import Foundation

/// Lists the output devices whose sound ClipFarm can record.
enum AudioOutputDevices {
    struct Device: Identifiable, Hashable {
        /// The Core Audio UID, which survives unplugging and reconnecting.
        let id: String
        let name: String
        let objectID: AudioObjectID

        var uid: String { id }
    }

    /// Every device that has an output stream, speakers and headphones included.
    static func available() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStream(id),
                  let name = string(id, kAudioObjectPropertyName),
                  let uid = string(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return Device(id: uid, name: name, objectID: id)
        }
    }

    /// The saved device when it is still connected, otherwise the system default.
    static func resolved(uid: String?) -> Device? {
        let devices = available()
        if let uid, let match = devices.first(where: { $0.uid == uid }) { return match }
        guard let defaultID = defaultOutputDeviceID() else { return devices.first }
        return devices.first(where: { $0.objectID == defaultID }) ?? devices.first
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &id
        ) == noErr, id != 0 else { return nil }
        return id
    }

    static func defaultOutputDeviceName() -> String? {
        guard let id = defaultOutputDeviceID() else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    private static func hasOutputStream(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value as String
    }
}
