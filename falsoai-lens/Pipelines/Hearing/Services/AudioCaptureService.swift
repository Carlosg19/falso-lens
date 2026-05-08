import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

enum AudioCaptureError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case microphonePermissionNotDetermined
    case inputFormatUnavailable
    case inputDeviceUnavailable(OSStatus)
    case inputAudioUnitUnavailable
    case inputDeviceSelectionFailed(deviceID: AudioDeviceID, status: OSStatus)
    case engineStartFailed(code: Int, message: String)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is denied for Falsoai Lens."
        case .microphonePermissionNotDetermined:
            return "Microphone permission has not been requested yet."
        case .inputFormatUnavailable:
            return "The microphone input format was unavailable."
        case let .inputDeviceUnavailable(status):
            return "No default microphone input device was available. Core Audio status \(status)."
        case .inputAudioUnitUnavailable:
            return "The microphone input audio unit was unavailable."
        case let .inputDeviceSelectionFailed(deviceID, status):
            return "Could not use audio input device \(deviceID). Core Audio status \(status)."
        case let .engineStartFailed(code, message):
            return "Microphone capture could not start. Core Audio status \(code). \(message)"
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
        case .inputFormatUnavailable, .inputDeviceUnavailable, .inputAudioUnitUnavailable, .engineStartFailed:
            return "Check that a microphone is connected and available."
        case .inputDeviceSelectionFailed:
            return "Choose another microphone or virtual cable input device, then try again."
        case .alreadyRunning:
            return "Stop the current capture before starting another one."
        }
    }
}

struct AudioCaptureConfiguration: Sendable, Equatable {
    var inputBus: AVAudioNodeBus
    var bufferSize: AVAudioFrameCount
    var inputDeviceID: AudioDeviceID?

    nonisolated static let `default` = AudioCaptureConfiguration(
        inputBus: 0,
        bufferSize: 1024,
        inputDeviceID: nil
    )
}

@MainActor
final class AudioCaptureService {
    private var engine: AVAudioEngine
    private let logger: Logger
    private var continuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var inputBus: AVAudioNodeBus = AudioCaptureConfiguration.default.inputBus
    private var hasInstalledTap = false

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
        let deviceID = try configuration.inputDeviceID ?? Self.defaultInputDeviceID()

        let inputNode = engine.inputNode
        try Self.setInputDevice(deviceID, on: inputNode)
        let format = try AudioInputDeviceService.inputFormat(for: deviceID)
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
        hasInstalledTap = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanupAfterFailedStart()
            throw Self.engineStartError(from: error)
        }
        isRunning = true

        logger.info(
            "Audio capture started deviceID=\(deviceID, privacy: .public), sampleRate=\(format.sampleRate, privacy: .public), channels=\(format.channelCount, privacy: .public), bufferSize=\(configuration.bufferSize, privacy: .public)"
        )

        return streamPair.stream
    }

    func stopCapture() {
        guard isRunning || continuation != nil else { return }

        if hasInstalledTap {
            engine.inputNode.removeTap(onBus: inputBus)
            hasInstalledTap = false
        }
        engine.stop()
        engine.reset()
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

    private func cleanupAfterFailedStart() {
        if hasInstalledTap {
            engine.inputNode.removeTap(onBus: inputBus)
            hasInstalledTap = false
        }
        engine.stop()
        engine.reset()
        continuation?.finish()
        continuation = nil
        inputBus = AudioCaptureConfiguration.default.inputBus
        isRunning = false
        engine = AVAudioEngine()
    }

    private nonisolated static func defaultInputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioCaptureError.inputDeviceUnavailable(status)
        }

        return deviceID
    }

    private nonisolated static func setInputDevice(
        _ deviceID: AudioDeviceID,
        on inputNode: AVAudioInputNode
    ) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioCaptureError.inputAudioUnitUnavailable
        }

        var selectedDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioCaptureError.inputDeviceSelectionFailed(
                deviceID: deviceID,
                status: status
            )
        }
    }

    private nonisolated static func engineStartError(from error: Error) -> AudioCaptureError {
        let nsError = error as NSError
        return AudioCaptureError.engineStartFailed(
            code: nsError.code,
            message: nsError.localizedDescription
        )
    }
}
