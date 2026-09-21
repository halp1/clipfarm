import AVFoundation
import CoreMedia
import Foundation

/// Holds the last stretch of encoded samples and drops whatever falls off the back.
///
/// Video samples are already compressed when they arrive here, so a few minutes costs
/// a few hundred megabytes rather than the hundreds of gigabytes raw frames would.
/// Audio arrives as PCM and gets compressed when a clip is written.
final class ClipBuffer {
    private var samples: [CMSampleBuffer] = []
    private let lock = NSLock()

    /// Kept beyond the clip length so the trim always has a keyframe to start from and
    /// a little room for samples that arrive out of order.
    private let slack: Double = 3

    /// How many seconds to keep. Set from the clip duration preference.
    var window: Double = 30 {
        didSet { lock.withLock { trimLocked() } }
    }

    private(set) var formatDescription: CMFormatDescription?

    func append(_ sample: CMSampleBuffer) {
        lock.withLock {
            if formatDescription == nil {
                formatDescription = CMSampleBufferGetFormatDescription(sample)
            }
            samples.append(sample)
            trimLocked()
        }
    }

    /// Drops everything older than the window, stopping at a keyframe so the remaining
    /// samples can still be decoded.
    private func trimLocked() {
        guard let newest = samples.last else { return }
        let newestTime = CMSampleBufferGetPresentationTimeStamp(newest)
        let cutoff = CMTimeSubtract(newestTime, CMTime(seconds: window + slack, preferredTimescale: 600))

        var firstKeepable = 0
        for (index, sample) in samples.enumerated() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time >= cutoff { break }
            if ClipBuffer.isKeyframe(sample) { firstKeepable = index }
        }
        if firstKeepable > 0 {
            samples.removeFirst(firstKeepable)
        }
    }

    /// Everything currently held, oldest first.
    func snapshot() -> [CMSampleBuffer] {
        lock.withLock { samples }
    }

    /// The samples covering the last `duration` seconds, starting at a keyframe.
    ///
    /// Returns nothing when the buffer has not filled up enough to contain a keyframe
    /// before the requested start.
    func trailing(_ duration: Double) -> (samples: [CMSampleBuffer], start: CMTime)? {
        lock.withLock {
            guard let newest = samples.last else { return nil }
            let newestTime = CMSampleBufferGetPresentationTimeStamp(newest)
            let target = CMTimeSubtract(newestTime, CMTime(seconds: duration, preferredTimescale: 600))

            var startIndex = 0
            var found = false
            for (index, sample) in samples.enumerated() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard ClipBuffer.isKeyframe(sample) else { continue }
                if time <= target {
                    startIndex = index
                    found = true
                } else if !found {
                    // The clip is longer than what has been recorded, so start at the
                    // first keyframe available.
                    startIndex = index
                    found = true
                    break
                } else {
                    break
                }
            }
            guard found else { return nil }
            let slice = Array(samples[startIndex...])
            guard let first = slice.first else { return nil }
            return (slice, CMSampleBufferGetPresentationTimeStamp(first))
        }
    }

    /// Samples at or after a given time, used to line the audio up with the video.
    func samples(from start: CMTime) -> [CMSampleBuffer] {
        lock.withLock {
            samples.filter { sample in
                let end = CMTimeAdd(
                    CMSampleBufferGetPresentationTimeStamp(sample),
                    CMSampleBufferGetDuration(sample)
                )
                return end >= start
            }
        }
    }

    func removeAll() {
        lock.withLock {
            samples.removeAll()
            formatDescription = nil
        }
    }

    var isEmpty: Bool { lock.withLock { samples.isEmpty } }

    /// Seconds between the oldest and newest sample held.
    var span: Double {
        lock.withLock {
            guard let first = samples.first, let last = samples.last else { return 0 }
            let start = CMSampleBufferGetPresentationTimeStamp(first)
            let end = CMSampleBufferGetPresentationTimeStamp(last)
            return CMTimeSubtract(end, start).seconds
        }
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first
        else { return true }
        // A sample is a keyframe unless it is explicitly marked as depending on others.
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }
}
