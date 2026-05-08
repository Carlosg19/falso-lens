import AVFoundation

enum HearingDependencies {
    static let captureEngineType = AVAudioEngine.self
    static let microphoneMediaType = AVMediaType.audio
    static let bundledExecutableName = "whisper-cli"
    static let bundledModelResourceName = "ggml-small"
    static let bundledModelResourceExtension = "bin"
    static let vadWindowDurationSeconds = 0.030
    static let vadThresholdDBFS = -40.0
    static let vadAdaptiveNoiseFloorMarginDB = 12.0
    static let vadMinimumAdaptiveThresholdDBFS = -60.0
    static let vadPaddingSeconds = 0.200
    static let vadMinimumVoicedDurationSeconds = 0.100
}
