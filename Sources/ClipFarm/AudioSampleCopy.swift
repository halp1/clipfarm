import AVFoundation
import CoreMedia
import Foundation

/// Copies an audio sample buffer into memory ClipFarm owns, interleaved.
///
/// Two problems get solved in one pass here.
///
/// ScreenCaptureKit and AVCaptureSession hand out buffers from a fixed pool and want
/// them back quickly. Holding the originals in a ring buffer drains that pool and audio
/// delivery stops within about a second, so the samples have to be copied out.
///
/// Both sources deliver non-interleaved float audio, one buffer per channel. Attaching
/// that layout to a new sample buffer fails, because a sample size only describes
/// interleaved data. Interleaving during the copy avoids that and matches what the AAC
/// encoder wants at save time.
enum AudioSampleCopy {
    /// Interleaved float32, the format everything downstream reads.
    static func interleavedFormat(
        sampleRate: Double,
        channels: Int
    ) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(4 * channels)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    static func copy(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let sourceFormat = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormat)?.pointee
        else { return nil }

        let frameCount = Int(CMSampleBufferGetNumSamples(sample))
        guard frameCount > 0 else { return nil }

        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        ) == noErr, listSize > 0 else { return nil }

        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { listMemory.deallocate() }
        let listPointer = listMemory.assumingMemoryBound(to: AudioBufferList.self)

        var sourceBlock: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &sourceBlock
        ) == noErr else { return nil }

        let sourceList = UnsafeMutableAudioBufferListPointer(listPointer)
        guard sourceList.count > 0 else { return nil }

        // A non-interleaved stream gives one buffer per channel. An interleaved one
        // gives a single buffer that already holds every channel.
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = isNonInterleaved
            ? sourceList.count
            : Int(sourceList[0].mNumberChannels)
        guard channels > 0 else { return nil }

        let byteCount = frameCount * channels * 4
        guard let destination = malloc(byteCount) else { return nil }
        let floats = destination.assumingMemoryBound(to: Float.self)

        if isNonInterleaved {
            for channel in 0..<channels {
                guard let data = sourceList[channel].mData?.assumingMemoryBound(to: Float.self)
                else { free(destination); return nil }
                let available = Int(sourceList[channel].mDataByteSize) / 4
                for frame in 0..<min(frameCount, available) {
                    floats[frame * channels + channel] = data[frame]
                }
            }
        } else {
            guard let data = sourceList[0].mData else { free(destination); return nil }
            let available = min(byteCount, Int(sourceList[0].mDataByteSize))
            destination.copyMemory(from: data, byteCount: available)
        }

        var outputASBD = interleavedFormat(sampleRate: asbd.mSampleRate, channels: channels)
        var outputFormat: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &outputASBD,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &outputFormat
        ) == noErr, let outputFormat else { free(destination); return nil }

        // The block buffer takes ownership of the allocation and frees it on release.
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: destination,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else { free(destination); return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: .invalid
        )
        var sizePerSample = 4 * channels

        var output: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: outputFormat,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizePerSample,
            sampleBufferOut: &output
        ) == noErr else { return nil }
        return output
    }
}
