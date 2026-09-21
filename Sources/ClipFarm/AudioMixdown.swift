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
    /// started late still lines up with the picture. Where two sources overlap they are
    /// summed, and the result is scaled down if that pushes past full scale.
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

            for run in contiguousRuns(source) {
                guard let first = run.first else { continue }
                let runStart = CMTimeSubtract(
                    CMSampleBufferGetPresentationTimeStamp(first),
                    start
                ).seconds
                guard runStart > -1 else { continue }

                // One converter per run. A converter holds on to frames it cannot emit
                // yet and releases them on a later call, so feeding it a run at a time
                // and writing the output as one continuous block keeps every frame at
                // the position it belongs. Converting sample by sample and placing each
                // result at its own timestamp writes those held frames twice, which is
                // audible as a short echo on anything percussive.
                guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                    continue
                }

                var writeIndex = Int((runStart * sampleRate).rounded())
                for sample in run {
                    guard let input = pcmBuffer(from: sample, format: sourceFormat),
                          let converted = convert(input, using: converter, to: format),
                          let channels = converted.floatChannelData
                    else { continue }

                    let frames = Int(converted.frameLength)
                    let sourceChannels = Int(converted.format.channelCount)
                    for channel in 0..<Int(channelCount) {
                        // A mono source feeds both output channels.
                        let pointer = channels[min(channel, sourceChannels - 1)]
                        for frame in 0..<frames {
                            let destination = writeIndex + frame
                            guard destination >= 0, destination < totalFrames else { continue }
                            mixed[channel][destination] += pointer[frame]
                        }
                    }
                    writeIndex += frames
                    wroteAnything = true
                }

                // Whatever the converter still holds belongs at the end of this run.
                if let tail = drain(converter, to: format), let channels = tail.floatChannelData {
                    let frames = Int(tail.frameLength)
                    let sourceChannels = Int(tail.format.channelCount)
                    for channel in 0..<Int(channelCount) {
                        let pointer = channels[min(channel, sourceChannels - 1)]
                        for frame in 0..<frames {
                            let destination = writeIndex + frame
                            guard destination >= 0, destination < totalFrames else { continue }
                            mixed[channel][destination] += pointer[frame]
                        }
                    }
                }
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

    /// Splits a source into stretches of samples that run back to back.
    ///
    /// A gap means the device stopped sending audio for a while, usually because nothing
    /// was playing. Each stretch is placed by its own timestamp, and within a stretch
    /// frames simply follow one another.
    private static func contiguousRuns(_ samples: [CMSampleBuffer]) -> [[CMSampleBuffer]] {
        var runs: [[CMSampleBuffer]] = []
        var current: [CMSampleBuffer] = []
        var expectedNext: CMTime?

        for sample in samples {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            if let expectedNext {
                // Half a buffer of slack absorbs ordinary rounding between callbacks.
                let drift = abs(CMTimeSubtract(timestamp, expectedNext).seconds)
                if drift > 0.02 {
                    runs.append(current)
                    current = []
                }
            }
            current.append(sample)
            let frames = CMSampleBufferGetNumSamples(sample)
            let rate = CMSampleBufferGetFormatDescription(sample)
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
                ?? sampleRate
            expectedNext = CMTimeAdd(
                timestamp,
                CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
            )
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Pulls out any frames the converter is still holding.
    private static func drain(
        _ converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            return nil
        }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        return output.frameLength > 0 ? output : nil
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

    /// Reads a sample buffer's interleaved float audio into an AVAudioPCMBuffer.
    ///
    /// Samples reach the ring buffer already interleaved, see `AudioSampleCopy`, so the
    /// bytes can be taken in one go.
    private static func pcmBuffer(
        from sample: CMSampleBuffer,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = Int(CMSampleBufferGetNumSamples(sample))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
              ),
              let block = CMSampleBufferGetDataBuffer(sample)
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else { return nil }

        let channels = Int(format.channelCount)
        let source = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
        let availableFrames = min(frames, totalLength / (4 * channels))

        if format.isInterleaved {
            guard let destination = buffer.floatChannelData?[0] else { return nil }
            destination.update(from: source, count: availableFrames * channels)
        } else {
            // Split the interleaved source back out, one buffer per channel.
            guard let channelData = buffer.floatChannelData else { return nil }
            for channel in 0..<channels {
                let destination = channelData[channel]
                for frame in 0..<availableFrames {
                    destination[frame] = source[frame * channels + channel]
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(availableFrames)
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
