import AVFoundation
import CoreMedia
import Foundation
import CoreGraphics
import ScreenCaptureKit
import VideoToolbox

/// Records the whole screen continuously and keeps the recent past in memory.
///
/// ScreenCaptureKit hands over raw frames, a single VideoToolbox session compresses
/// them, and `ClipBuffer` holds the result. Because one encoder session runs for the
/// life of the capture, the samples splice together without a seam when a clip is cut.
final class CaptureEngine: NSObject, @unchecked Sendable {
    static let shared = CaptureEngine()

    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private let videoQueue = DispatchQueue(label: "dev.haelp.clipfarm.video")
    private let audioQueue = DispatchQueue(label: "dev.haelp.clipfarm.audio")

    let videoBuffer = ClipBuffer()
    /// What the machine plays, captured by ScreenCaptureKit.
    let audioBuffer = ClipBuffer()
    /// A microphone or interface, captured separately.
    let inputRecorder = InputAudioRecorder()

    private(set) var isRunning = false
    private var frameRate: Int32 = 60
    private var captureSize = CGSize(width: 1920, height: 1080)

    /// Posted when the capture stops on its own, usually because the display changed
    /// or permission was withdrawn.
    static let stateChanged = Notification.Name("ClipFarmCaptureStateChanged")

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: Preferences.didChange,
            object: nil
        )
    }

    @objc private func preferencesChanged() {
        let duration = Preferences.shared.clipDuration
        videoBuffer.window = duration
        audioBuffer.window = duration
        inputRecorder.setWindow(duration)

        // A change of audio device or source takes effect without restarting the
        // screen capture, since the microphone runs on its own session.
        guard isRunning else { return }
        let preferences = Preferences.shared
        let wantedDevice = preferences.inputDeviceUID
        if preferences.audioSource.needsInputDevice {
            if !inputRecorder.isRunning || wantedDevice != activeInputDeviceUID {
                activeInputDeviceUID = wantedDevice
                inputRecorder.start(deviceUID: wantedDevice)
                inputRecorder.setWindow(duration)
            }
        } else if inputRecorder.isRunning {
            inputRecorder.stop()
            activeInputDeviceUID = nil
        }
    }

    /// The device the input recorder is currently on, so a preference change can tell
    /// whether it actually needs to switch.
    private var activeInputDeviceUID: String?

    /// Asks for screen recording permission, which macOS shows as a prompt the first time.
    func requestPermission() async -> Bool {
        // CGRequestScreenCaptureAccess is what puts the system dialog on screen. Once a
        // user has answered it macOS remembers, and the only way back is the Screen &
        // System Audio Recording list in System Settings.
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }
        Log.error("Screen recording permission is not granted")
        return false
    }

    /// Whether macOS currently allows the screen to be recorded.
    var hasScreenPermission: Bool { CGPreflightScreenCaptureAccess() }

    func start() async {
        guard !isRunning else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                Log.error("No display to record")
                return
            }

            // The whole display, every time. ClipFarm never records a single window.
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: frameRate)
            config.queueDepth = 8
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.capturesAudio = Preferences.shared.audioSource.needsSystemAudio
            config.sampleRate = 48000
            config.channelCount = 2

            captureSize = CGSize(width: config.width, height: config.height)
            try setUpEncoder(width: Int32(config.width), height: Int32(config.height))

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()

            self.stream = stream
            isRunning = true

            // Start the microphone when the chosen source asks for one.
            if Preferences.shared.audioSource.needsInputDevice {
                if await AudioDevices.requestPermission() {
                    activeInputDeviceUID = Preferences.shared.inputDeviceUID
                    inputRecorder.start(deviceUID: activeInputDeviceUID)
                } else {
                    Log.error("Microphone permission was declined, recording the screen without it")
                }
            }
            preferencesChanged()
            Log.info("Recording \(config.width)x\(config.height) at \(frameRate) fps")
            NotificationCenter.default.post(name: CaptureEngine.stateChanged, object: nil)
        } catch {
            Log.error("Could not start recording: \(error.localizedDescription)")
            isRunning = false
            NotificationCenter.default.post(name: CaptureEngine.stateChanged, object: nil)
        }
    }

    func stop() async {
        guard isRunning, let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        isRunning = false
        tearDownEncoder()
        inputRecorder.stop()
        activeInputDeviceUID = nil
        videoBuffer.removeAll()
        audioBuffer.removeAll()
        NotificationCenter.default.post(name: CaptureEngine.stateChanged, object: nil)
        Log.info("Recording stopped")
    }

    func restart() async {
        await stop()
        await start()
    }

    // MARK: Encoder

    private func setUpEncoder(width: Int32, height: Int32) throws {
        tearDownEncoder()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(
                domain: "dev.haelp.clipfarm",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "The video encoder would not start"]
            )
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_High_AutoLevel
        )
        // One keyframe a second bounds how far back a trim has to reach.
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: frameRate)
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: 1.0)
        )
        // B frames would reorder output, which makes trimming harder than it needs to be.
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        let pixels = Double(width) * Double(height)
        let bitrate = Int(min(max(pixels * 0.12, 6_000_000), 40_000_000))
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrate)
        )
        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
        Log.info("Encoder ready at \(bitrate / 1_000_000) Mbps")
    }

    private func tearDownEncoder() {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }
    }

    private func encode(_ imageBuffer: CVImageBuffer, at time: CMTime, duration: CMTime) {
        guard let compressionSession else { return }
        VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: time,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.videoBuffer.append(sampleBuffer)
        }
    }
}

extension CaptureEngine: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit sends frames even when nothing moved. Those carry a
            // status that says so, and encoding them wastes the buffer.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
                let info = attachments.first,
                let rawStatus = info[.status] as? Int,
                let status = SCFrameStatus(rawValue: rawStatus),
                status == .complete,
                let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }

            encode(
                imageBuffer,
                at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                duration: CMTime(value: 1, timescale: frameRate)
            )

        case .audio:
            audioBuffer.append(sampleBuffer)

        default:
            break
        }
    }
}

extension CaptureEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Recording stopped on its own: \(error.localizedDescription)")
        isRunning = false
        self.stream = nil
        NotificationCenter.default.post(name: CaptureEngine.stateChanged, object: nil)

        // A display change or a wake from sleep ends the stream. Pick it back up.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.start()
        }
    }
}
