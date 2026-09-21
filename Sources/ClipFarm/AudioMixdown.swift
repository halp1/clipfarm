import AVFoundation
import CoreMedia
import Foundation

/// Sums two audio sources into one track.
///
/// System audio and a microphone arrive as separate streams at whatever rate and
/// channel count each device uses. Writing them as two tracks in one MP4 does not work
/// well, since most players and upload sites only play the first. So both get resampled
/// to a common format, added together sample by sample, and written as a single track.
enum AudioMixdown {
    /// What everything is converted to before being added together.
    static let sampleRate: Double = 48000
    static let channelCount: AVAudioChannelCount = 2
    private static let framesPerChunk: AVAudioFrameCount = 1024

    static var outputFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }

    /// Mixes the given sources and returns samples timed from `start`.
    ///
    /// Each source is placed on the timeline by its own timestamps, so a microphone that
    /// started late still lines up with the picture.
    static func mix(
        sources: [[CMSampleBuffer]],
        start: CMTime,
        duration: Double
    ) -> [CMSampleBuffer] {
        let format = outputFormat
        let totalFrames = Int(duration * sampleRate) + Int(sampleRate)
        guard totalFrames > 0 else { return [] }

        // One accumulator per channel, holding the whole clip.
        var mixed = [[Float]](
            repeating: [Float](repeating: 0, count: totalFrames),
            count: Int(channelCount)
        )
        var wroteAnything = false

        for source in sources where !source.isEmpty {
            guard let sourceFormat = source.first.flatMap({
                CMSampleBufferGetFormatDescription($0)
            }).flatMap({ AVAudioFormat(cmAudioFormatDescription: $0) }) else { continue }

            let converter = AVAudioConverter(from: sourceFormat, to: format)

            for sample in source {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                let offsetSeconds = CMTimeSubtract(timestamp, start).seconds
                guard offsetSeconds > -1 else { continue }
                let frameOffset = Int(offsetSeconds * sampleRate)

                guard let inputBuffer = pcmBuffer(from: sample, format: sourceFormat) else { continue }
                guard let converted = convert(inputBuffer, using: converter, to: format) else { continue }
                guard let channels = converted.floatChannelData else { continue }

                let frames = Int(converted.frameLength)
                for channel in 0..<Int(channelCount) {
                    // A mono source feeds both output channels.
                    let sourceChannel = min(channel, Int(converted.format.channelCount) - 1)
                    let pointer = channels[sourceChannel]
                    for frame in 0..<frames {
                        let destination = frameOffset + frame
                        guard destination >= 0, destination < totalFrames else { continue }
                        mixed[channel][destination] += pointer[frame]
                    }
                }
                wroteAnything = true
            }
        }

        guard wroteAnything else { return [] }

        // Adding two loud sources can push past full scale, so pull the whole mix down
        // if anything clipped rather than letting it distort.
        var peak: Float = 1
        for channel in mixed {
            for value in channel where abs(value) > peak { peak = abs(value) }
        }
        if peak > 1 {
            let scale = 1 / peak
            for channel in 0..<mixed.count {
                for frame in 0..<mixed[channel].count {
                    mixed[channel][frame] *= scale
                }
            }
        }

        return sampleBuffers(from: mixed, format: format, start: start)
    }

    /// Cuts the accumulated float data into sample buffers the writer can take.
    private static func sampleBuffers(
        from mixed: [[Float]],
        format: AVAudioFormat,
        start: CMTime
    ) -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        let totalFrames = mixed.first?.count ?? 0
        var frame = 0

        while frame < totalFrames {
            let count = min(Int(framesPerChunk), totalFrames - frame)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            guard let channels = buffer.floatChannelData else { break }
            for channel in 0..<mixed.count {
                mixed[channel].withUnsafeBufferPointer { source in
                    channels[channel].update(from: source.baseAddress! + frame, count: count)
                }
            }

            let timestamp = CMTimeAdd(
                start,
                CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(sampleRate))
            )
            if let sample = makeSampleBuffer(from: buffer, at: timestamp) {
                output.append(sample)
            }
            frame += count
        }
        return output
    }

    /// Wraps a sample buffer's audio in an AVAudioPCMBuffer so AVAudioConverter can read it.
    private static func pcmBuffer(
        from sample: CMSampleBuffer,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
              )
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        if input.format == format { return input }

        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error {
            Log.error("Audio conversion failed: \(error.localizedDescription)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    private static func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        at time: CMTime
    ) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard copyStatus == noErr else { return nil }
        return sampleBuffer
    }
}
