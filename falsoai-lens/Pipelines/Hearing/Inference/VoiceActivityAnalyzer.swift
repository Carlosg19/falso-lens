import Foundation

enum VoiceActivityAnalyzer {
    struct Result {
        let trimRange: Range<Int>?
        let effectiveThresholdDBFS: Double
        let noiseFloorDBFS: Double
        let maxWindowDBFS: Double
        let meanWindowDBFS: Double
        let windowCount: Int
    }

    static func trimRange(
        for samples: [Float],
        sampleRate: Double,
        configuration: RMSVoiceActivityDetectorConfiguration
    ) -> Range<Int>? {
        analyze(
            for: samples,
            sampleRate: sampleRate,
            configuration: configuration
        ).trimRange
    }

    static func analyze(
        for samples: [Float],
        sampleRate: Double,
        configuration: RMSVoiceActivityDetectorConfiguration
    ) -> Result {
        guard !samples.isEmpty, sampleRate > 0 else {
            return Result(
                trimRange: nil,
                effectiveThresholdDBFS: configuration.thresholdDBFS,
                noiseFloorDBFS: -200,
                maxWindowDBFS: -200,
                meanWindowDBFS: -200,
                windowCount: 0
            )
        }

        let windowSamples = max(1, Int((configuration.windowDurationSeconds * sampleRate).rounded(.toNearestOrAwayFromZero)))
        let windowCount = samples.count / windowSamples
        guard windowCount > 0 else {
            return Result(
                trimRange: nil,
                effectiveThresholdDBFS: configuration.thresholdDBFS,
                noiseFloorDBFS: -200,
                maxWindowDBFS: -200,
                meanWindowDBFS: -200,
                windowCount: 0
            )
        }

        var windowLevels: [Double] = []
        windowLevels.reserveCapacity(windowCount)

        for windowIndex in 0..<windowCount {
            let start = windowIndex * windowSamples
            let end = start + windowSamples
            windowLevels.append(rmsDBFS(samples[start..<end]))
        }

        let sortedWindowLevels = windowLevels.sorted()
        let noiseFloorIndex = min(
            sortedWindowLevels.count - 1,
            max(0, Int((Double(sortedWindowLevels.count - 1) * 0.20).rounded(.down)))
        )
        let noiseFloorDBFS = sortedWindowLevels[noiseFloorIndex]
        let adaptiveThreshold = noiseFloorDBFS + configuration.adaptiveNoiseFloorMarginDB
        let effectiveThresholdDBFS = max(
            configuration.minimumAdaptiveThresholdDBFS,
            min(configuration.thresholdDBFS, adaptiveThreshold)
        )
        let maxWindowDBFS = windowLevels.max() ?? -200
        let meanWindowDBFS = windowLevels.reduce(0, +) / Double(windowLevels.count)

        var firstVoicedWindow: Int?
        var lastVoicedWindow: Int?

        for (windowIndex, dbfs) in windowLevels.enumerated() {
            guard dbfs >= effectiveThresholdDBFS else { continue }

            if firstVoicedWindow == nil {
                firstVoicedWindow = windowIndex
            }
            lastVoicedWindow = windowIndex
        }

        guard let firstVoicedWindow, let lastVoicedWindow else {
            return Result(
                trimRange: nil,
                effectiveThresholdDBFS: effectiveThresholdDBFS,
                noiseFloorDBFS: noiseFloorDBFS,
                maxWindowDBFS: maxWindowDBFS,
                meanWindowDBFS: meanWindowDBFS,
                windowCount: windowCount
            )
        }

        let voicedDuration = Double(lastVoicedWindow - firstVoicedWindow + 1) * configuration.windowDurationSeconds
        guard voicedDuration >= configuration.minimumVoicedDurationSeconds else {
            return Result(
                trimRange: nil,
                effectiveThresholdDBFS: effectiveThresholdDBFS,
                noiseFloorDBFS: noiseFloorDBFS,
                maxWindowDBFS: maxWindowDBFS,
                meanWindowDBFS: meanWindowDBFS,
                windowCount: windowCount
            )
        }

        let paddingSamples = max(0, Int((configuration.paddingSeconds * sampleRate).rounded(.toNearestOrAwayFromZero)))
        let startSample = max(0, firstVoicedWindow * windowSamples - paddingSamples)
        let endSample = min(samples.count, (lastVoicedWindow + 1) * windowSamples + paddingSamples)

        guard startSample < endSample else {
            return Result(
                trimRange: nil,
                effectiveThresholdDBFS: effectiveThresholdDBFS,
                noiseFloorDBFS: noiseFloorDBFS,
                maxWindowDBFS: maxWindowDBFS,
                meanWindowDBFS: meanWindowDBFS,
                windowCount: windowCount
            )
        }

        return Result(
            trimRange: startSample..<endSample,
            effectiveThresholdDBFS: effectiveThresholdDBFS,
            noiseFloorDBFS: noiseFloorDBFS,
            maxWindowDBFS: maxWindowDBFS,
            meanWindowDBFS: meanWindowDBFS,
            windowCount: windowCount
        )
    }

    static func rmsDBFS(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return -200 }

        let squareTotal = samples.reduce(Double(0)) { partialResult, sample in
            partialResult + Double(sample * sample)
        }
        let rms = sqrt(squareTotal / Double(samples.count))
        return 20 * log10(max(rms, 1e-10))
    }
}
