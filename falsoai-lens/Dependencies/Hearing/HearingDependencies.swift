import AVFoundation

enum HearingDependencies {
    static let captureEngineType = AVAudioEngine.self
    static let microphoneMediaType = AVMediaType.audio
    static let bundledExecutableName = "whisper-cli"
    static let bundledModelResourceName = "ggml-small"
    static let bundledModelResourceExtension = "bin"
}
