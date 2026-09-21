import AVFoundation
import CoreAudio
import Foundation

/// Records the audio going out of one specific output device.
///
/// Core Audio can tap a device's output stream, which is what lets ClipFarm record
/// what a particular set of speakers or headphones is playing rather than whatever
/// happens to be the system default. The tap is wrapped in a private aggregate device
/// so an IOProc can read it.
///
/// This needs the microphone permission, since a tap can hear anything the machine
/// plays. macOS asks for it the first time and denies the tap silently otherwise, so
/// permission is requested before the tap is built.
final class AudioOutputTap {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var format: AudioStreamBasicDescription?
    private var formatDescription: CMFormatDescription?

    /// Where captured samples go. The engine hands this the recording buffer.
    private let onSamples: (CMSampleBuffer) -> Void

    private(set) var isRunning = false
    private(set) var deviceName: String?

    init(onSamples: @escaping (CMSampleBuffer) -> Void) {
        self.onSamples = onSamples
    }

    deinit {
        stop()
    }

    /// Starts tapping the given device, or the current default output when none is named.
    @discardableResult
    func start(deviceUID: String?) -> Bool {
        stop()

        guard let device = AudioOutputDevices.resolved(uid: deviceUID) else {
            Log.error("No output device to record")
            return false
        }

        // Exclude nothing, so every app playing through this device is captured.
        // The mixdown initializer takes an include-list, and an empty one records
        // silence, which is a very easy mistake to make.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "ClipFarm (\(device.name))"
        description.isPrivate = true
        // Leave playback alone. The tap listens without muting what you hear.
        description.muteBehavior = .unmuted
        // Bind to this device's stream, so only its output is recorded.
        description.deviceUID = device.uid
        description.stream = 0

        var tap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else {
            Log.error("Could not tap \(device.name), error \(tapStatus)")
            return false
        }
        tapID = tap

        guard let tapFormat = Self.tapFormat(tapID) else {
            Log.error("Could not read the tap's format")
            stop()
            return false
        }
        // The aggregate device is what an IOProc can actually be attached to. Keeping
        // the tapped device as the sub-device means playback is untouched.
        let aggregateUID = UUID().uuidString
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ClipFarm capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: Self.tapUID(tapID) ?? description.uuid.uuidString
            ]]
        ]

        var aggregate: AudioObjectID = 0
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            settings as CFDictionary,
            &aggregate
        )
        guard aggregateStatus == noErr else {
            Log.error("Could not open a capture device for \(device.name), error \(aggregateStatus)")
            stop()
            return false
        }
        aggregateID = aggregate

        // The tap advertises a rate, but audio arrives at whatever rate the aggregate
        // settles on, which follows the device. A headphone set running at 44100 with a
        // tap claiming 48000 makes every clip play about 9% fast, which is audible as
        // everything being slightly sharp. Trust the aggregate.
        var effectiveFormat = tapFormat
        if let deviceRate = Self.nominalSampleRate(aggregateID), deviceRate > 0,
           abs(deviceRate - tapFormat.mSampleRate) > 1 {
            Log.info("Tap says \(tapFormat.mSampleRate) Hz but the device runs at \(deviceRate) Hz, using the device")
            effectiveFormat.mSampleRate = deviceRate
        }
        format = effectiveFormat

        formatDescription = Self.makeFormatDescription(effectiveFormat)
        guard formatDescription != nil else {
            Log.error("Could not describe the tap's audio format")
            stop()
            return false
        }

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &proc,
            aggregateID,
            nil
        ) { [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData, at: inputTime)
        }
        guard procStatus == noErr, let proc else {
            Log.error("Could not start reading from \(device.name), error \(procStatus)")
            stop()
            return false
        }
        procID = proc

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            Log.error("Could not start \(device.name), error \(startStatus)")
            stop()
            return false
        }

        isRunning = true
        deviceName = device.name
        Log.info("Recording the output of \(device.name) at \(Int(effectiveFormat.mSampleRate)) Hz")
        return true
    }

    func stop() {
        if aggregateID != 0, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        format = nil
        formatDescription = nil
        isRunning = false
        deviceName = nil
    }

    /// Wraps each block of tapped audio in a sample buffer and passes it along.
    private func handle(
        _ inputData: UnsafePointer<AudioBufferList>,
        at inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let format, let formatDescription else { return }
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard list.count > 0 else { return }

        let bytesPerFrame = max(Int(format.mBytesPerFrame), 1)
        let frames = Int(list[0].mDataByteSize) / bytesPerFrame
        guard frames > 0, let data = list[0].mData else { return }

        // The host time on the callback is the clock ScreenCaptureKit also uses, so the
        // audio lines up with the picture without any extra bookkeeping.
        let timestamp = CMClockMakeHostTimeFromSystemUnits(inputTime.pointee.mHostTime)

        var block: CMBlockBuffer?
        let byteCount = frames * bytesPerFrame
        guard let copy = malloc(byteCount) else { return }
        copy.copyMemory(from: data, byteCount: byteCount)

        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: copy,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else {
            free(copy)
            return
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.mSampleRate)),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame

        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        onSamples(sample)
    }

    /// What the device is actually running at, which is what the samples arrive as.
    private static func nominalSampleRate(_ deviceID: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr
        else { return nil }
        return rate
    }

    /// The tap's own UID, which is what the aggregate's tap list has to reference.
    private static func tapUID(_ tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value as String
    }

    private static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 0
        else { return nil }
        return asbd
    }

    private static func makeFormatDescription(
        _ asbd: AudioStreamBasicDescription
    ) -> CMFormatDescription? {
        var description = asbd
        var output: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &output
        ) == noErr else { return nil }
        return output
    }
}
