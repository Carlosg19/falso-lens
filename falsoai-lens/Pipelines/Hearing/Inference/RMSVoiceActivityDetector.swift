import AVFoundation
import Foundation
import OSLog

struct RMSVoiceActivityDetectorConfiguration: Sendable, Equatable {
    var windowDurationSeconds: TimeInterval
    var thresholdDBFS: Double
    var adaptiveNoiseFloorMarginDB: Double
    var minimumAdaptiveThresholdDBFS: Double
    var paddingSeconds: TimeInterval
    var minimumVoicedDurationSeconds: TimeInterval

    nonisolated static let `default` = RMSVoiceActivityDetectorConfiguration(
        windowDurationSeconds: HearingDependencies.vadWindowDurationSeconds,
        thresholdDBFS: HearingDependencies.vadThresholdDBFS,
        adaptiveNoiseFloorMarginDB: HearingDependencies.vadAdaptiveNoiseFloorMarginDB,
        minimumAdaptiveThresholdDBFS: HearingDependencies.vadMinimumAdaptiveThresholdDBFS,
        paddingSeconds: HearingDependencies.vadPaddingSeconds,
        minimumVoicedDurationSeconds: HearingDependencies.vadMinimumVoicedDurationSeconds
    )
}

actor RMSVoiceActivityDetector: VoiceActivityDetector {
    private let configuration: RMSVoiceActivityDetectorConfiguration
    private let logger: Logger

    init(
        configuration: RMSVoiceActivityDetectorConfiguration = .default,
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "VoiceActivity"
        )
    ) {
        self.configuration = configuration
        self.logger = logger
    }

    func trimSilence(in audioFile: URL) async throws -> URL? {
        try Self.trimSilenceInMonoFloatWAV(
            in: audioFile,
            configuration: configuration,
            logger: logger
        )
    }

    private nonisolated static func trimSilenceInMonoFloatWAV(
        in audioFile: URL,
        configuration: RMSVoiceActivityDetectorConfiguration,
        logger: Logger?
    ) throws -> URL? {
        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            throw VoiceActivityError.audioFileNotFound(audioFile)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioFile)
        } catch {
            throw VoiceActivityError.decodeFailed(error.localizedDescription)
        }

        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1 else {
            throw VoiceActivityError.unsupportedAudioFormat(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            )
        }

        guard file.length > 0 else {
            logger?.info("vad.noVoice inputFrames=0")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw VoiceActivityError.decodeFailed("Could not allocate an audio buffer for \(file.length) frames.")
        }

        do {
            try file.read(into: buffer)
        } catch {
            throw VoiceActivityError.decodeFailed(error.localizedDescription)
        }

        guard let channelData = buffer.floatChannelData?[0] else {
            throw VoiceActivityError.decodeFailed("Decoded audio did not contain float channel data.")
        }

        let sampleCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: sampleCount))
        let analysis = VoiceActivityAnalyzer.analyze(
            for: samples,
            sampleRate: format.sampleRate,
            configuration: configuration
        )

        guard let trimRange = analysis.trimRange else {
            logger?.info(
                "vad.noVoice inputDurationSeconds=\(Double(sampleCount) / format.sampleRate, privacy: .public), windowCount=\(analysis.windowCount, privacy: .public), effectiveThresholdDBFS=\(analysis.effectiveThresholdDBFS, privacy: .public), noiseFloorDBFS=\(analysis.noiseFloorDBFS, privacy: .public), maxWindowDBFS=\(analysis.maxWindowDBFS, privacy: .public), meanWindowDBFS=\(analysis.meanWindowDBFS, privacy: .public)"
            )
            return nil
        }

        let trimmedSamples = Array(samples[trimRange])
        let trimmedURL = Self.makeTemporaryOutputURL()
        do {
            try Self.writeMonoFloatWAV(
                samples: trimmedSamples,
                format: format,
                to: trimmedURL
            )
        } catch let error as VoiceActivityError {
            throw error
        } catch {
            throw VoiceActivityError.encodeFailed(error.localizedDescription)
        }

        let inputDuration = Double(sampleCount) / format.sampleRate
        let outputDuration = Double(trimmedSamples.count) / format.sampleRate
        logger?.info(
            "vad.trimmed inputDurationSeconds=\(inputDuration, privacy: .public), outputDurationSeconds=\(outputDuration, privacy: .public), voicedRatio=\(outputDuration / max(inputDuration, 0.001), privacy: .public), startSample=\(trimRange.lowerBound, privacy: .public), endSample=\(trimRange.upperBound, privacy: .public), effectiveThresholdDBFS=\(analysis.effectiveThresholdDBFS, privacy: .public), noiseFloorDBFS=\(analysis.noiseFloorDBFS, privacy: .public), maxWindowDBFS=\(analysis.maxWindowDBFS, privacy: .public)"
        )

        return trimmedURL
    }

    #if DEBUG
    nonisolated static func runVADSmokeCheck() {
        let sampleRate = 16_000.0
        let silence = Array(repeating: Float(0), count: Int(sampleRate))
        let burst = (0..<Int(sampleRate)).map { index in
            Float(sin((2 * Double.pi * 440 * Double(index)) / sampleRate))
        }
        let samples = silence + burst + silence
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            assertionFailure("VAD smoke check: could not create AVAudioFormat")
            return
        }

        let inputURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vad-smoke-input-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            try writeMonoFloatWAV(samples: samples, format: format, to: inputURL)
            defer {
                try? FileManager.default.removeItem(at: inputURL)
            }

            guard let outputURL = try trimSilenceInMonoFloatWAV(
                in: inputURL,
                configuration: .default,
                logger: nil
            ) else {
                assertionFailure("VAD smoke check: expected trimmed output URL")
                return
            }
            defer {
                try? FileManager.default.removeItem(at: outputURL)
            }

            let outputFile = try AVAudioFile(forReading: outputURL)
            let duration = Double(outputFile.length) / outputFile.processingFormat.sampleRate
            let minimumExpected = 1.0 + RMSVoiceActivityDetectorConfiguration.default.paddingSeconds - 0.030
            let maximumExpected = 1.0 + (2 * RMSVoiceActivityDetectorConfiguration.default.paddingSeconds) + 0.030
            assert(
                duration >= minimumExpected && duration <= maximumExpected,
                "VAD smoke check: expected duration \(minimumExpected)...\(maximumExpected), got \(duration)"
            )
        } catch {
            assertionFailure("VAD smoke check failed: \(error)")
        }
    }
    #endif

    private nonisolated static func makeTemporaryOutputURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vad-trimmed-\(UUID().uuidString)")
            .appendingPathExtension("wav")
    }

    private nonisolated static func writeMonoFloatWAV(
        samples: [Float],
        format: AVAudioFormat,
        to url: URL
    ) throws {
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw VoiceActivityError.encodeFailed("Could not allocate an output audio buffer for \(samples.count) samples.")
        }

        outputBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let outputData = outputBuffer.floatChannelData?[0] else {
            throw VoiceActivityError.encodeFailed("Output audio buffer did not contain float channel data.")
        }

        samples.withUnsafeBufferPointer { pointer in
            outputData.update(from: pointer.baseAddress!, count: samples.count)
        }

        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try outputFile.write(from: outputBuffer)
    }
}
