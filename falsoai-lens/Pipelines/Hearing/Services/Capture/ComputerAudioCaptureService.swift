import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

enum ComputerAudioCaptureError: LocalizedError {
    case alreadyRunning
    case screenRecordingPermissionDenied
    case noDisplayAvailable
    case unsupportedAudioFormat(formatID: AudioFormatID)
    case sampleBufferUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Computer audio capture is already running."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required before computer audio can be captured."
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
        case .noDisplayAvailable:
            return "Connect or wake a display, then try again."
        case .unsupportedAudioFormat, .sampleBufferUnavailable:
            return "Try again. If this repeats, capture a Console log from the ComputerAudioCapture category."
        }
    }
}

struct ComputerAudioCaptureConfiguration: Sendable, Equatable {
    var sampleRate: Int
    var channelCount: Int
    var excludesCurrentProcessAudio: Bool

    nonisolated static let `default` = ComputerAudioCaptureConfiguration(
        sampleRate: 48_000,
        channelCount: 2,
        excludesCurrentProcessAudio: true
    )
}

@MainActor
final class ComputerAudioCaptureService: LiveAudioCaptureProvider {
    private let logger: Logger
    private let sampleHandlerQueue = DispatchQueue(label: "com.falsoai.lens.computer-audio-capture")
    private var stream: SCStream?
    private var streamOutput: ComputerAudioStreamOutput?

    private(set) var isRunning = false

    var transcriptSource: TranscriptSource {
        TranscriptSource(
            source: .computer,
            captureMethod: .screenCaptureKit
        )
    }

    init(
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "ComputerAudioCapture"
        )
    ) {
        self.logger = logger
    }

    func setInputDeviceID(_ deviceID: AudioDeviceID?) {
    }

    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer> {
        try await startCapture(configuration: .default)
    }

    func startCapture(
        configuration: ComputerAudioCaptureConfiguration
    ) async throws -> AsyncStream<CapturedAudioBuffer> {
        guard !isRunning else {
            throw ComputerAudioCaptureError.alreadyRunning
        }

        try prepareForCapture()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw ComputerAudioCaptureError.noDisplayAvailable
        }

        let streamPair = AsyncStream<CapturedAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        let streamOutput = ComputerAudioStreamOutput(
            continuation: streamPair.continuation,
            logger: logger
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = max(display.width, 2)
        streamConfiguration.height = max(display.height, 2)
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        streamConfiguration.queueDepth = 3
        streamConfiguration.showsCursor = false
        streamConfiguration.capturesAudio = true
        streamConfiguration.captureMicrophone = false
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
            type: .screen,
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
            "Computer audio capture started displayID=\(display.displayID, privacy: .public), sampleRate=\(configuration.sampleRate, privacy: .public), channels=\(configuration.channelCount, privacy: .public), excludesCurrentProcessAudio=\(configuration.excludesCurrentProcessAudio, privacy: .public)"
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
            try? await currentStream.stopCapture()
            try? currentStream.removeStreamOutput(currentOutput, type: .audio)
            try? currentStream.removeStreamOutput(currentOutput, type: .screen)
        }

        currentOutput?.finish()

        logger.info("Computer audio capture stopped")
    }

    private func prepareForCapture() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ComputerAudioCaptureError.screenRecordingPermissionDenied
        }
    }
}

private nonisolated final class ComputerAudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedAudioBuffer>.Continuation
    private let logger: Logger

    init(
        continuation: AsyncStream<CapturedAudioBuffer>.Continuation,
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
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        do {
            let buffer = try ScreenCaptureAudioBufferReader.capturedAudioBuffer(from: sampleBuffer)
            continuation.yield(buffer)
        } catch {
            logger.error("Failed to copy computer sample buffer: \(String(describing: error), privacy: .public)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Computer audio stream stopped with error: \(String(describing: error), privacy: .public)")
        continuation.finish()
    }
}
