import AVFoundation

enum HearingDependencies {
    static let captureEngineType = AVAudioEngine.self
    static let microphoneMediaType = AVMediaType.audio
    static let bundledExecutableName = "whisper-cli"
    static let bundledModelResourceName = "ggml-base"
    static let bundledModelResourceExtension = "bin"
}
