import AVFoundation
import Foundation
import OSLog

enum AudioCaptureError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case microphonePermissionNotDetermined
    case inputFormatUnavailable
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is denied for Falsoai Lens."
        case .microphonePermissionNotDetermined:
            return "Microphone permission has not been requested yet."
        case .inputFormatUnavailable:
            return "The microphone input format was unavailable."
        case .alreadyRunning:
            return "Audio capture is already running."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Grant Microphone access in System Settings, then try again."
        case .microphonePermissionNotDetermined:
            return "Request Microphone access before starting audio capture."
        case .inputFormatUnavailable:
            return "Check that a microphone is connected and available."
        case .alreadyRunning:
            return "Stop the current capture before starting another one."
        }
    }
}

struct AudioCaptureConfiguration: Sendable, Equatable {
    var inputBus: AVAudioNodeBus
    var bufferSize: AVAudioFrameCount

    nonisolated static let `default` = AudioCaptureConfiguration(
        inputBus: 0,
        bufferSize: 1024
    )
}

@MainActor
final class AudioCaptureService {
    private let engine: AVAudioEngine
    private let logger: Logger
    private var continuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var inputBus: AVAudioNodeBus = AudioCaptureConfiguration.default.inputBus

    private(set) var isRunning = false

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "AudioCapture"
        )
    ) {
        self.engine = engine
        self.logger = logger
    }

    func startCapture(
        configuration: AudioCaptureConfiguration = .default
    ) throws -> AsyncStream<CapturedAudioBuffer> {
        guard !isRunning else {
            throw AudioCaptureError.alreadyRunning
        }

        try prepareForCapture()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: configuration.inputBus)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.inputFormatUnavailable
        }

        let streamPair = AsyncStream<CapturedAudioBuffer>.makeStream()
        continuation = streamPair.continuation
        inputBus = configuration.inputBus

        let streamContinuation = streamPair.continuation
        inputNode.installTap(
            onBus: configuration.inputBus,
            bufferSize: configuration.bufferSize,
            format: format
        ) { buffer, time in
            let capturedBuffer = CapturedAudioBuffer(copying: buffer, at: time)
            streamContinuation.yield(capturedBuffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        logger.info(
            "Audio capture started sampleRate=\(format.sampleRate, privacy: .public), channels=\(format.channelCount, privacy: .public), bufferSize=\(configuration.bufferSize, privacy: .public)"
        )

        return streamPair.stream
    }

    func stopCapture() {
        guard isRunning || continuation != nil else { return }

        engine.inputNode.removeTap(onBus: inputBus)
        engine.stop()
        continuation?.finish()
        continuation = nil
        inputBus = AudioCaptureConfiguration.default.inputBus
        isRunning = false

        logger.info("Audio capture stopped")
    }

    private func prepareForCapture() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw AudioCaptureError.microphonePermissionDenied
        case .notDetermined:
            throw AudioCaptureError.microphonePermissionNotDetermined
        @unknown default:
            throw AudioCaptureError.microphonePermissionDenied
        }
    }
}
