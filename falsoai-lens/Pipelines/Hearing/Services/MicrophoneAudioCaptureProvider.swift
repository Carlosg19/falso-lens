import CoreAudio
import Foundation

@MainActor
final class MicrophoneAudioCaptureProvider: LiveAudioCaptureProvider {
    private let audioCaptureService: AudioCaptureService
    private var inputDeviceID: AudioDeviceID?
    private var inputDeviceName: String?

    var isRunning: Bool {
        audioCaptureService.isRunning
    }

    var transcriptSource: TranscriptSource {
        TranscriptSource(
            source: .microphone,
            captureMethod: .avAudioEngine,
            inputDevice: inputDeviceName ?? "System Default"
        )
    }

    init(audioCaptureService: AudioCaptureService? = nil) {
        self.audioCaptureService = audioCaptureService ?? AudioCaptureService()
    }

    func setInputDeviceID(_ deviceID: AudioDeviceID?) {
        guard !isRunning else { return }
        inputDeviceID = deviceID
        inputDeviceName = deviceID.flatMap { try? AudioInputDeviceService.displayName(for: $0) }
    }

    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer> {
        var configuration = AudioCaptureConfiguration.default
        configuration.inputDeviceID = inputDeviceID
        return try audioCaptureService.startCapture(configuration: configuration)
    }

    func stopCapture() async {
        audioCaptureService.stopCapture()
    }
}
