import AVFoundation
import CoreMedia
import Foundation

/// Records one input device into a rolling buffer, alongside the screen capture.
///
/// ScreenCaptureKit gives us what the machine plays. A microphone is a separate device,
/// so it runs through its own AVCaptureSession and lands in its own buffer. The two get
/// mixed when a clip is written.
final class InputAudioRecorder: NSObject, @unchecked Sendable {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "dev.haelp.clipfarm.input-audio")

    let buffer = ClipBuffer(kind: .audio)
    private(set) var isRunning = false
    private(set) var currentDeviceName: String?

    /// Starts recording the chosen device. Passing nothing uses the system default.
    func start(deviceUID: String?) {
        stop()
        guard let device = AudioDevices.resolvedDevice(preferredUID: deviceUID) else {
            Log.error("No audio input device to record from")
            return
        }
        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                Log.error("Could not record from \(device.localizedName)")
                return
            }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                Log.error("Could not attach the audio output")
                return
            }
            session.addOutput(output)

            session.startRunning()
            self.session = session
            isRunning = true
            currentDeviceName = device.localizedName
            Log.info("Recording audio from \(device.localizedName)")
        } catch {
            Log.error("Could not open the audio device: \(error.localizedDescription)")
        }
    }

    func stop() {
        session?.stopRunning()
        session = nil
        isRunning = false
        currentDeviceName = nil
        buffer.removeAll()
    }

    func setWindow(_ seconds: Double) {
        buffer.window = seconds
    }
}

extension InputAudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        // Same reason as the system audio path: the capture session needs its buffers back.
        guard let copy = AudioSampleCopy.copy(sampleBuffer) else { return }
        buffer.append(copy)
    }
}
