import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

enum ComputerMicrophoneAudioCaptureError: LocalizedError {
    case alreadyRunning
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case microphonePermissionNotDetermined
    case noDisplayAvailable
    case unsupportedAudioFormat(formatID: AudioFormatID)
    case sampleBufferUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Computer and microphone audio capture is already running."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required before computer audio can be captured."
        case .microphonePermissionDenied:
            return "Microphone permission is required before microphone audio can be captured."
        case .microphonePermissionNotDetermined:
            return "Microphone permission has not been requested yet."
        case .noDisplayAvailable:
            return "No display was available for computer audio capture."
        case let .unsupportedAudioFormat(formatID):
            return "ScreenCaptureKit returned an unsupported audio format ID \(formatID)."
        case let .sampleBufferUnavailable(status):
            return "Could not read audio samples from ScreenCaptureKit. Core Media status \(status)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .alreadyRunning:
            return "Stop the current live transcription before starting another one."
        case .screenRecordingPermissionDenied:
            return "Grant Screen Recording permission in System Settings, quit and reopen the app, then try again."
        case .microphonePermissionDenied:
            return "Grant Microphone access in System Settings, then try again."
        case .microphonePermissionNotDetermined:
            return "Use the Request Microphone button first, then start live transcription."
        case .noDisplayAvailable:
            return "Connect or wake a display, then try again."
        case .unsupportedAudioFormat, .sampleBufferUnavailable:
            return "Try again. If this repeats, capture a Console log from the MixedAudioCapture category."
        }
    }
}

struct ComputerMicrophoneAudioCaptureConfiguration: Sendable, Equatable {
    var sampleRate: Int
    var channelCount: Int
    var excludesCurrentProcessAudio: Bool

    nonisolated static let `default` = ComputerMicrophoneAudioCaptureConfiguration(
        sampleRate: 48_000,
        channelCount: 2,
        excludesCurrentProcessAudio: true
    )
}

@MainActor
final class ComputerMicrophoneAudioCaptureService {
    private let logger: Logger
    private let sampleHandlerQueue = DispatchQueue(label: "com.falsoai.lens.mixed-audio-capture")
    private var stream: SCStream?
    private var streamOutput: ComputerMicrophoneAudioStreamOutput?

    private(set) var isRunning = false

    init(
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "MixedAudioCapture"
        )
    ) {
        self.logger = logger
    }

    func startCapture(
        configuration: ComputerMicrophoneAudioCaptureConfiguration = .default
    ) async throws -> AsyncStream<CapturedAudioPacket> {
        guard !isRunning else {
            throw ComputerMicrophoneAudioCaptureError.alreadyRunning
        }

        try prepareForCapture()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw ComputerMicrophoneAudioCaptureError.noDisplayAvailable
        }

        let streamPair = AsyncStream<CapturedAudioPacket>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        let streamOutput = ComputerMicrophoneAudioStreamOutput(
            continuation: streamPair.continuation,
            logger: logger
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = max(display.width, 2)
        streamConfiguration.height = max(display.height, 2)
        streamConfiguration.queueDepth = 3
        streamConfiguration.showsCursor = false
        streamConfiguration.capturesAudio = true
        streamConfiguration.captureMicrophone = true
        streamConfiguration.sampleRate = configuration.sampleRate
        streamConfiguration.channelCount = configuration.channelCount
        streamConfiguration.excludesCurrentProcessAudio = configuration.excludesCurrentProcessAudio

        let stream = SCStream(
            filter: filter,
            configuration: streamConfiguration,
            delegate: streamOutput
        )

        try stream.addStreamOutput(
            streamOutput,
            type: .audio,
            sampleHandlerQueue: sampleHandlerQueue
        )
        try stream.addStreamOutput(
            streamOutput,
            type: .microphone,
            sampleHandlerQueue: sampleHandlerQueue
        )

        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = streamOutput
        isRunning = true

        streamPair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                await self?.stopCapture()
            }
        }

        logger.info(
            "Mixed audio capture started displayID=\(display.displayID, privacy: .public), sampleRate=\(configuration.sampleRate, privacy: .public), channels=\(configuration.channelCount, privacy: .public), excludesCurrentProcessAudio=\(configuration.excludesCurrentProcessAudio, privacy: .public)"
        )

        return streamPair.stream
    }

    func stopCapture() async {
        guard isRunning || stream != nil || streamOutput != nil else { return }

        let currentStream = stream
        let currentOutput = streamOutput
        stream = nil
        streamOutput = nil
        isRunning = false

        if let currentStream, let currentOutput {
            try? currentStream.removeStreamOutput(currentOutput, type: .audio)
            try? currentStream.removeStreamOutput(currentOutput, type: .microphone)
            try? await currentStream.stopCapture()
        }

        currentOutput?.finish()

        logger.info("Mixed audio capture stopped")
    }

    private func prepareForCapture() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ComputerMicrophoneAudioCaptureError.screenRecordingPermissionDenied
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw ComputerMicrophoneAudioCaptureError.microphonePermissionDenied
        case .notDetermined:
            throw ComputerMicrophoneAudioCaptureError.microphonePermissionNotDetermined
        @unknown default:
            throw ComputerMicrophoneAudioCaptureError.microphonePermissionDenied
        }
    }
}

private nonisolated final class ComputerMicrophoneAudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedAudioPacket>.Continuation
    private let logger: Logger

    init(
        continuation: AsyncStream<CapturedAudioPacket>.Continuation,
        logger: Logger
    ) {
        self.continuation = continuation
        self.logger = logger
    }

    func finish() {
        continuation.finish()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let source: CapturedAudioSource
        switch type {
        case .audio:
            source = .computer
        case .microphone:
            source = .microphone
        default:
            return
        }

        do {
            let buffer = try Self.capturedAudioBuffer(from: sampleBuffer)
            continuation.yield(
                CapturedAudioPacket(
                    source: source,
                    buffer: buffer
                )
            )
        } catch {
            logger.error("Failed to copy \(source.rawValue, privacy: .public) sample buffer: \(String(describing: error), privacy: .public)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Mixed audio stream stopped with error: \(String(describing: error), privacy: .public)")
        continuation.finish()
    }

    private static func capturedAudioBuffer(from sampleBuffer: CMSampleBuffer) throws -> CapturedAudioBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else {
            throw ComputerMicrophoneAudioCaptureError.unsupportedAudioFormat(formatID: 0)
        }

        guard streamDescription.mFormatID == kAudioFormatLinearPCM else {
            throw ComputerMicrophoneAudioCaptureError.unsupportedAudioFormat(
                formatID: streamDescription.mFormatID
            )
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let channelCount = max(1, Int(streamDescription.mChannelsPerFrame))
        let maximumBuffers = max(1, channelCount)
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
            throw ComputerMicrophoneAudioCaptureError.sampleBufferUnavailable(status)
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
            hostTime: UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
        )
    }

    private static func copySamples(
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

    private static func decodeSample(
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
