import CoreAudio
import CoreMedia
import Foundation

enum ScreenCaptureAudioBufferReader {
    nonisolated static func capturedAudioBuffer(from sampleBuffer: CMSampleBuffer) throws -> CapturedAudioBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else {
            throw ComputerAudioCaptureError.unsupportedAudioFormat(formatID: 0)
        }

        guard streamDescription.mFormatID == kAudioFormatLinearPCM else {
            throw ComputerAudioCaptureError.unsupportedAudioFormat(
                formatID: streamDescription.mFormatID
            )
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let channelCount = max(1, Int(streamDescription.mChannelsPerFrame))
        let hostTime = UInt64(
            CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000
        )

        guard frameCount > 0 else {
            return CapturedAudioBuffer(
                samples: [],
                sampleRate: streamDescription.mSampleRate,
                channelCount: channelCount,
                frameCount: 0,
                hostTime: hostTime
            )
        }

        var bufferListSizeNeeded = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, bufferListSizeNeeded > 0 else {
            throw ComputerAudioCaptureError.sampleBufferUnavailable(sizeStatus)
        }

        let maximumBuffers = maximumBufferCount(forAudioBufferListByteCount: bufferListSizeNeeded)
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        defer { audioBufferList.unsafeMutablePointer.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: maximumBuffers),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            throw ComputerAudioCaptureError.sampleBufferUnavailable(status)
        }

        let samples = try copySamples(
            from: audioBufferList,
            streamDescription: streamDescription,
            frameCount: frameCount,
            channelCount: channelCount
        )

        return CapturedAudioBuffer(
            samples: samples,
            sampleRate: streamDescription.mSampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            hostTime: hostTime
        )
    }

    private nonisolated static func maximumBufferCount(forAudioBufferListByteCount byteCount: Int) -> Int {
        let singleBufferByteCount = AudioBufferList.sizeInBytes(maximumBuffers: 1)
        guard byteCount > singleBufferByteCount else { return 1 }

        let additionalByteCount = byteCount - singleBufferByteCount
        let additionalBuffers = Int(
            (Double(additionalByteCount) / Double(MemoryLayout<AudioBuffer>.stride)).rounded(.up)
        )
        return 1 + max(0, additionalBuffers)
    }

    private nonisolated static func copySamples(
        from audioBufferList: UnsafeMutableAudioBufferListPointer,
        streamDescription: AudioStreamBasicDescription,
        frameCount: Int,
        channelCount: Int
    ) throws -> [Float] {
        let formatFlags = streamDescription.mFormatFlags
        let isNonInterleaved = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = max(1, Int(streamDescription.mBitsPerChannel / 8))

        var samples: [Float] = []
        samples.reserveCapacity(frameCount * channelCount)

        if isNonInterleaved {
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    let bufferIndex = min(channelIndex, audioBufferList.count - 1)
                    guard let data = audioBufferList[bufferIndex].mData else {
                        samples.append(0)
                        continue
                    }

                    samples.append(
                        decodeSample(
                            data: data,
                            byteOffset: frameIndex * bytesPerSample,
                            streamDescription: streamDescription
                        )
                    )
                }
            }
        } else {
            guard let data = audioBufferList.first?.mData else {
                return Array(repeating: 0, count: frameCount * channelCount)
            }

            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    let sampleIndex = (frameIndex * channelCount) + channelIndex
                    samples.append(
                        decodeSample(
                            data: data,
                            byteOffset: sampleIndex * bytesPerSample,
                            streamDescription: streamDescription
                        )
                    )
                }
            }
        }

        return samples
    }

    private nonisolated static func decodeSample(
        data: UnsafeMutableRawPointer,
        byteOffset: Int,
        streamDescription: AudioStreamBasicDescription
    ) -> Float {
        let formatFlags = streamDescription.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bytesPerSample = max(1, Int(streamDescription.mBitsPerChannel / 8))
        let samplePointer = UnsafeRawPointer(data).advanced(by: byteOffset)

        if isFloat, bytesPerSample == MemoryLayout<Float>.size {
            return samplePointer.load(as: Float.self)
        }

        if isFloat, bytesPerSample == MemoryLayout<Double>.size {
            return Float(samplePointer.load(as: Double.self))
        }

        if isSignedInteger, bytesPerSample == MemoryLayout<Int16>.size {
            return Float(samplePointer.load(as: Int16.self)) / Float(Int16.max)
        }

        if isSignedInteger, bytesPerSample == MemoryLayout<Int32>.size {
            return Float(samplePointer.load(as: Int32.self)) / Float(Int32.max)
        }

        if !isSignedInteger, bytesPerSample == MemoryLayout<UInt8>.size {
            return (Float(samplePointer.load(as: UInt8.self)) - 128) / 128
        }

        return 0
    }
}
