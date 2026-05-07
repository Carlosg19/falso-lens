import AVFoundation

enum HearingDependencies {
    static let captureEngineType = AVAudioEngine.self
    static let microphoneMediaType = AVMediaType.audio
    static let bundledExecutableSubdirectory = "BundledResources/Bin"
    static let bundledModelSubdirectory = "BundledResources/Models"
    static let bundledExecutableName = "whisper-cli"
    static let bundledModelResourceName = "ggml-base"
    static let bundledModelResourceExtension = "bin"
}
