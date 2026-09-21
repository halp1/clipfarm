import AVFoundation
import CoreMedia
import Foundation

/// Writes the buffered samples out as an MP4.
///
/// Video samples are already H.264, so they are appended as they are. Audio is PCM in
/// the buffer and gets compressed to AAC on the way out. Timestamps are shifted so the
/// clip starts at zero.
enum ClipExporter {
    enum ExportError: LocalizedError {
        case nothingRecorded
        case noVideoFormat
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .nothingRecorded:
                return "There is nothing recorded yet. Give it a few seconds and try again."
            case .noVideoFormat:
                return "The recording has not produced a usable frame yet."
            case .writerFailed(let reason):
                return reason
            }
        }
    }

    /// Builds a clip of the last `duration` seconds and returns where it was written.
    ///
    /// `systemAudio` holds what the machine played and `inputAudio` holds the microphone.
    /// Whichever are present get summed into one track.
    static func export(
        duration: Double,
        videoBuffer: ClipBuffer,
        systemAudio: ClipBuffer?,
        inputAudio: ClipBuffer?,
        to url: URL
    ) async throws -> URL {
        guard let (videoSamples, startTime) = videoBuffer.trailing(duration),
              !videoSamples.isEmpty
        else { throw ExportError.nothingRecorded }

        guard let videoFormat = videoBuffer.formatDescription else {
            throw ExportError.noVideoFormat
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormat
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.writerFailed("The clip could not be set up for writing.")
        }
        writer.add(videoInput)

        // Collect whichever audio sources were recorded and sum them into one track.
        let clipLength = CMTimeSubtract(
            CMSampleBufferGetPresentationTimeStamp(videoSamples.last!),
            startTime
        ).seconds
        var sources: [[CMSampleBuffer]] = []
        if let systemAudio {
            let samples = systemAudio.samples(from: startTime)
            if !samples.isEmpty { sources.append(samples) }
        }
        if let inputAudio {
            let samples = inputAudio.samples(from: startTime)
            if !samples.isEmpty { sources.append(samples) }
        }

        let audioSamples = sources.isEmpty
            ? []
            : AudioMixdown.mix(sources: sources, start: startTime, duration: max(clipLength, duration))

        var audioInput: AVAssetWriterInput?
        if !audioSamples.isEmpty {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: Int(AudioMixdown.channelCount),
                AVSampleRateKey: AudioMixdown.sampleRate,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw ExportError.writerFailed(
                writer.error?.localizedDescription ?? "The clip could not be written."
            )
        }
        writer.startSession(atSourceTime: .zero)

        // Both tracks have to be fed at the same time. Finishing the video track before
        // starting the audio one leaves the writer waiting on audio that never comes.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await append(samples: videoSamples, offset: startTime, to: videoInput)
            }
            if let audioInput {
                group.addTask {
                    try await append(samples: audioSamples, offset: startTime, to: audioInput)
                }
            }
            try await group.waitForAll()
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw ExportError.writerFailed(
                writer.error?.localizedDescription ?? "The clip could not be written."
            )
        }
        return url
    }

    /// Feeds samples to an input, rebasing each one so the clip begins at zero.
    private static func append(
        samples: [CMSampleBuffer],
        offset: CMTime,
        to input: AVAssetWriterInput
    ) async throws {
        let queue = DispatchQueue(label: "dev.haelp.clipfarm.export")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var index = 0
            // The writer calls this block again whenever it drains, including after the
            // last sample has gone in, so finishing has to be recorded. Resuming a
            // continuation twice traps.
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard index < samples.count else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let sample = samples[index]
                    index += 1
                    guard let shifted = retime(sample, by: offset) else { continue }
                    if !input.append(shifted) {
                        finished = true
                        input.markAsFinished()
                        continuation.resume(
                            throwing: ExportError.writerFailed("A frame could not be written.")
                        )
                        return
                    }
                }
            }
        }
    }

    /// Moves a sample back by `offset` so the first one lands at zero.
    private static func retime(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &count
        ) == noErr else { return nil }

        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(),
            count: max(Int(count), 1)
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: count,
            arrayToFill: &timings,
            entriesNeededOut: &count
        ) == noErr else { return nil }

        for i in 0..<timings.count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeSubtract(
                    timings[i].presentationTimeStamp,
                    offset
                )
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }

        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: CMItemCount(timings.count),
            sampleTimingArray: &timings,
            sampleBufferOut: &output
        ) == noErr else { return nil }
        return output
    }

    /// A filename that sorts by date and will not collide on the CDN.
    static func makeFilename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: date)
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "clipfarm-\(stamp)-\(suffix).mp4"
    }
}
