import CoreAudio
import Foundation

@MainActor
protocol LiveAudioCaptureProvider: AnyObject {
    var isRunning: Bool { get }
    var transcriptSource: TranscriptSource { get }

    func setInputDeviceID(_ deviceID: AudioDeviceID?)
    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer>
    func stopCapture() async
}
