import Accelerate
import AudioLinkCore
import Foundation

public enum SignalKind: String, Codable, CaseIterable, Sendable {
    case logarithmicSweep
    case linearSweep
    case shortChirp
    case maximumLengthSequence
    case impulse
    case silence
    case bandLimitedNoise
}

public enum SweepDirection: String, Codable, CaseIterable, Sendable {
    case ascending
    case descending
}

public enum SignalPolarity: String, Codable, CaseIterable, Sendable {
    case positive
    case inverted

    fileprivate var multiplier: Float {
        switch self {
        case .positive: 1
        case .inverted: -1
        }
    }
}

public struct TestSignalConfiguration: Codable, Equatable, Sendable {
    public let kind: SignalKind
    public let sampleRate: SampleRate
    /// Active signal duration. Pre-roll and post-roll are additional.
    public let duration: DurationSeconds
    public let startFrequencyHertz: Double
    public let endFrequencyHertz: Double
    public let amplitude: Float
    public let preRollSilence: DurationSeconds
    public let postRollSilence: DurationSeconds
    public let fadeIn: DurationSeconds
    public let fadeOut: DurationSeconds
    public let channelCount: Int
    public let deterministicSeed: UInt64
    public let sweepDirection: SweepDirection
    public let polarity: SignalPolarity
    public let maximumLengthSequenceOrder: Int

    public init(
        kind: SignalKind,
        sampleRate: SampleRate,
        duration: DurationSeconds,
        startFrequencyHertz: Double = 20,
        endFrequencyHertz: Double = 20_000,
        amplitude: Float = 0.5,
        preRollSilence: DurationSeconds = .zero,
        postRollSilence: DurationSeconds = .zero,
        fadeIn: DurationSeconds = .zero,
        fadeOut: DurationSeconds = .zero,
        channelCount: Int = 1,
        deterministicSeed: UInt64 = 0xA0D1_01A5_1A8B_1E5D,
        sweepDirection: SweepDirection = .ascending,
        polarity: SignalPolarity = .positive,
        maximumLengthSequenceOrder: Int = 16
    ) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.duration = duration
        self.startFrequencyHertz = startFrequencyHertz
        self.endFrequencyHertz = endFrequencyHertz
        self.amplitude = amplitude
        self.preRollSilence = preRollSilence
        self.postRollSilence = postRollSilence
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.channelCount = channelCount
        self.deterministicSeed = deterministicSeed
        self.sweepDirection = sweepDirection
        self.polarity = polarity
        self.maximumLengthSequenceOrder = maximumLengthSequenceOrder
    }
}

public enum SignalGenerationError: Error, Equatable, Sendable {
    case nonFiniteFrequency(parameter: String, value: Double)
    case negativeFrequency(parameter: String, value: Double)
    case frequencyExceedsNyquist(parameter: String, value: Double, nyquist: Double)
    case invalidFrequencyRange(start: Double, end: Double, kind: SignalKind)
    case logarithmicSweepRequiresPositiveFrequency(start: Double, end: Double)
    case invalidAmplitude(Float)
    case invalidChannelCount(Int)
    case durationTooShort(DurationSeconds, sampleRate: SampleRate)
    case invalidFadeLengths(fadeInFrames: Int, fadeOutFrames: Int, activeFrames: Int)
    case unsupportedMaximumLengthSequenceOrder(Int)
    case sampleCountOverflow
    case generatedNonFiniteSample(index: Int)
}

extension SignalGenerationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nonFiniteFrequency:
            "Signal frequencies must be finite."
        case .negativeFrequency:
            "Signal frequencies cannot be negative."
        case .frequencyExceedsNyquist:
            "Signal frequency cannot exceed the Nyquist limit."
        case .invalidFrequencyRange:
            "The signal frequency range is invalid for the selected signal kind."
        case .logarithmicSweepRequiresPositiveFrequency:
            "A logarithmic sweep requires two distinct frequencies greater than zero."
        case .invalidAmplitude:
            "Amplitude must be finite and in the normalized range from zero through one."
        case .invalidChannelCount:
            "Channel count must be between one and 32."
        case .durationTooShort:
            "Signal duration must contain at least one sample."
        case .invalidFadeLengths:
            "Fade-in and fade-out must fit inside the active signal without overlapping."
        case .unsupportedMaximumLengthSequenceOrder:
            "Maximum Length Sequence order must be between two and 16."
        case .sampleCountOverflow:
            "The requested signal is too large to represent in memory."
        case .generatedNonFiniteSample:
            "Signal generation produced NaN or infinity."
        }
    }
}

public struct GeneratedSignal: Equatable, Sendable {
    public let configuration: TestSignalConfiguration
    public let audio: AudioSampleBuffer
    /// Frame range containing the generated content, excluding silence padding.
    public let activeFrameRange: Range<Int>
    /// Absolute frame containing the impulse for an impulse signal.
    public let impulseFrame: Int?

    public init(
        configuration: TestSignalConfiguration,
        audio: AudioSampleBuffer,
        activeFrameRange: Range<Int>,
        impulseFrame: Int? = nil
    ) {
        self.configuration = configuration
        self.audio = audio
        self.activeFrameRange = activeFrameRange
        self.impulseFrame = impulseFrame
    }

    public var activeSampleCount: SampleCount {
        SampleCount(rawValue: Int64(activeFrameRange.count))
    }

    public var activeDuration: DurationSeconds {
        activeSampleCount.duration(at: configuration.sampleRate)
    }
}

public struct TestSignalGenerator: Sendable {
    public init() {}

    public func generate(configuration: TestSignalConfiguration) throws -> GeneratedSignal {
        let dimensions = try validate(configuration)
        let polarity = configuration.polarity.multiplier
        var activeSamples: [Float]
        var localImpulseFrame: Int?

        switch configuration.kind {
        case .logarithmicSweep:
            activeSamples = logarithmicSweep(configuration, frameCount: dimensions.activeFrames)
            localImpulseFrame = nil
        case .linearSweep, .shortChirp:
            activeSamples = linearSweep(configuration, frameCount: dimensions.activeFrames)
            localImpulseFrame = nil
        case .maximumLengthSequence:
            activeSamples = maximumLengthSequence(configuration, frameCount: dimensions.activeFrames)
            localImpulseFrame = nil
        case .impulse:
            activeSamples = [Float](repeating: 0, count: dimensions.activeFrames)
            let impulseFrame = min(dimensions.fadeInFrames, dimensions.activeFrames - 1)
            activeSamples[impulseFrame] = configuration.amplitude
            localImpulseFrame = impulseFrame
        case .silence:
            activeSamples = [Float](repeating: 0, count: dimensions.activeFrames)
            localImpulseFrame = nil
        case .bandLimitedNoise:
            activeSamples = try bandLimitedNoise(configuration, frameCount: dimensions.activeFrames)
            localImpulseFrame = nil
        }

        if configuration.kind != .impulse, configuration.kind != .silence {
            applyRaisedCosineFades(
                to: &activeSamples,
                fadeInFrames: dimensions.fadeInFrames,
                fadeOutFrames: dimensions.fadeOutFrames
            )
        }
        if polarity != 1 {
            var multiplier = polarity
            activeSamples.withUnsafeMutableBufferPointer { storage in
                guard let baseAddress = storage.baseAddress else { return }
                vDSP_vsmul(
                    baseAddress,
                    1,
                    &multiplier,
                    baseAddress,
                    1,
                    vDSP_Length(storage.count)
                )
            }
        }
        if let invalidIndex = activeSamples.firstIndex(where: { !$0.isFinite }) {
            throw SignalGenerationError.generatedNonFiniteSample(index: invalidIndex)
        }

        let planarSamples: [Float]
        if configuration.channelCount == 1,
           dimensions.preRollFrames == 0,
           dimensions.totalFrames == dimensions.activeFrames {
            // Transfer the active Array's copy-on-write storage directly when
            // no layout transformation or padding is required.
            planarSamples = activeSamples
        } else {
            var paddedPlanarSamples = [Float](repeating: 0, count: dimensions.totalSamples)
            for channel in 0..<configuration.channelCount {
                let destinationStart = channel * dimensions.totalFrames + dimensions.preRollFrames
                paddedPlanarSamples.replaceSubrange(
                    destinationStart..<(destinationStart + dimensions.activeFrames),
                    with: activeSamples
                )
            }
            planarSamples = paddedPlanarSamples
        }

        let format = AudioFormatDescriptor(
            sampleRate: configuration.sampleRate,
            channelCount: configuration.channelCount,
            bitDepth: 32,
            isInterleaved: false
        )
        let buffer = try AudioSampleBuffer(samples: planarSamples, format: format)
        let activeRange = dimensions.preRollFrames..<(dimensions.preRollFrames + dimensions.activeFrames)
        return GeneratedSignal(
            configuration: configuration,
            audio: buffer,
            activeFrameRange: activeRange,
            impulseFrame: localImpulseFrame.map { dimensions.preRollFrames + $0 }
        )
    }

    private struct Dimensions {
        let activeFrames: Int
        let preRollFrames: Int
        let totalFrames: Int
        let totalSamples: Int
        let fadeInFrames: Int
        let fadeOutFrames: Int
    }

    private func validate(_ configuration: TestSignalConfiguration) throws -> Dimensions {
        let nyquist = configuration.sampleRate.hertz / 2
        for (name, frequency) in [
            ("startFrequencyHertz", configuration.startFrequencyHertz),
            ("endFrequencyHertz", configuration.endFrequencyHertz)
        ] {
            guard frequency.isFinite else {
                throw SignalGenerationError.nonFiniteFrequency(parameter: name, value: frequency)
            }
            guard frequency >= 0 else {
                throw SignalGenerationError.negativeFrequency(parameter: name, value: frequency)
            }
            guard frequency <= nyquist else {
                throw SignalGenerationError.frequencyExceedsNyquist(
                    parameter: name,
                    value: frequency,
                    nyquist: nyquist
                )
            }
        }
        guard configuration.amplitude.isFinite, (0...1).contains(configuration.amplitude) else {
            throw SignalGenerationError.invalidAmplitude(configuration.amplitude)
        }
        guard (1...32).contains(configuration.channelCount) else {
            throw SignalGenerationError.invalidChannelCount(configuration.channelCount)
        }
        switch configuration.kind {
        case .logarithmicSweep:
            guard configuration.startFrequencyHertz > 0,
                  configuration.endFrequencyHertz > 0,
                  configuration.startFrequencyHertz != configuration.endFrequencyHertz else {
                throw SignalGenerationError.logarithmicSweepRequiresPositiveFrequency(
                    start: configuration.startFrequencyHertz,
                    end: configuration.endFrequencyHertz
                )
            }
        case .linearSweep, .shortChirp, .bandLimitedNoise:
            guard configuration.startFrequencyHertz < configuration.endFrequencyHertz else {
                throw SignalGenerationError.invalidFrequencyRange(
                    start: configuration.startFrequencyHertz,
                    end: configuration.endFrequencyHertz,
                    kind: configuration.kind
                )
            }
        case .maximumLengthSequence:
            guard (2...16).contains(configuration.maximumLengthSequenceOrder) else {
                throw SignalGenerationError.unsupportedMaximumLengthSequenceOrder(
                    configuration.maximumLengthSequenceOrder
                )
            }
        case .impulse, .silence:
            break
        }

        let activeFrames = try integerFrameCount(
            duration: configuration.duration,
            sampleRate: configuration.sampleRate,
            mustBePositive: true
        )
        let preRollFrames = try integerFrameCount(
            duration: configuration.preRollSilence,
            sampleRate: configuration.sampleRate,
            mustBePositive: false
        )
        let postRollFrames = try integerFrameCount(
            duration: configuration.postRollSilence,
            sampleRate: configuration.sampleRate,
            mustBePositive: false
        )
        let fadeInFrames = try integerFrameCount(
            duration: configuration.fadeIn,
            sampleRate: configuration.sampleRate,
            mustBePositive: false
        )
        let fadeOutFrames = try integerFrameCount(
            duration: configuration.fadeOut,
            sampleRate: configuration.sampleRate,
            mustBePositive: false
        )
        let (combinedFadeFrames, fadeOverflow) = fadeInFrames.addingReportingOverflow(fadeOutFrames)
        guard !fadeOverflow, combinedFadeFrames <= activeFrames else {
            throw SignalGenerationError.invalidFadeLengths(
                fadeInFrames: fadeInFrames,
                fadeOutFrames: fadeOutFrames,
                activeFrames: activeFrames
            )
        }

        let (withPreRoll, preOverflow) = activeFrames.addingReportingOverflow(preRollFrames)
        let (totalFrames, postOverflow) = withPreRoll.addingReportingOverflow(postRollFrames)
        let (totalSamples, sampleOverflow) = totalFrames.multipliedReportingOverflow(
            by: configuration.channelCount
        )
        guard !preOverflow, !postOverflow, !sampleOverflow else {
            throw SignalGenerationError.sampleCountOverflow
        }
        return Dimensions(
            activeFrames: activeFrames,
            preRollFrames: preRollFrames,
            totalFrames: totalFrames,
            totalSamples: totalSamples,
            fadeInFrames: fadeInFrames,
            fadeOutFrames: fadeOutFrames
        )
    }

    private func integerFrameCount(
        duration: DurationSeconds,
        sampleRate: SampleRate,
        mustBePositive: Bool
    ) throws -> Int {
        let exactFrameCount = duration.value * sampleRate.hertz
        let roundedFrameCount = exactFrameCount.rounded()
        guard exactFrameCount.isFinite,
              roundedFrameCount >= 0,
              roundedFrameCount < Double(Int.max) else {
            throw SignalGenerationError.sampleCountOverflow
        }
        let frameCount = Int(roundedFrameCount)
        if mustBePositive, frameCount == 0 {
            throw SignalGenerationError.durationTooShort(duration, sampleRate: sampleRate)
        }
        return frameCount
    }

    private func orderedFrequencies(_ configuration: TestSignalConfiguration) -> (start: Double, end: Double) {
        switch configuration.sweepDirection {
        case .ascending:
            (configuration.startFrequencyHertz, configuration.endFrequencyHertz)
        case .descending:
            (configuration.endFrequencyHertz, configuration.startFrequencyHertz)
        }
    }

    private func logarithmicSweep(
        _ configuration: TestSignalConfiguration,
        frameCount: Int
    ) -> [Float] {
        let frequencies = orderedFrequencies(configuration)
        let sampleRate = configuration.sampleRate.hertz
        let duration = Double(frameCount) / sampleRate
        let logarithmicRatio = log(frequencies.end / frequencies.start)
        let phaseScale = 2 * Double.pi * frequencies.start * duration / logarithmicRatio

        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let phase = phaseScale * (exp(logarithmicRatio * time / duration) - 1)
            return configuration.amplitude * Float(sin(phase))
        }
    }

    private func linearSweep(
        _ configuration: TestSignalConfiguration,
        frameCount: Int
    ) -> [Float] {
        let frequencies = orderedFrequencies(configuration)
        let sampleRate = configuration.sampleRate.hertz
        let duration = Double(frameCount) / sampleRate
        let frequencySlope = (frequencies.end - frequencies.start) / duration

        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let phase = 2 * Double.pi * (
                frequencies.start * time + 0.5 * frequencySlope * time * time
            )
            return configuration.amplitude * Float(sin(phase))
        }
    }

    private func maximumLengthSequence(
        _ configuration: TestSignalConfiguration,
        frameCount: Int
    ) -> [Float] {
        let order = configuration.maximumLengthSequenceOrder
        let registerMask = UInt32((UInt64(1) << UInt64(order)) - 1)
        var register = UInt32(truncatingIfNeeded: configuration.deterministicSeed) & registerMask
        if register == 0 { register = 1 }
        let feedbackMask = Self.maximumLengthFeedbackMasks[order] ?? 0

        return (0..<frameCount).map { _ in
            let output = register & 1
            register >>= 1
            if output == 1 { register ^= feedbackMask }
            return output == 1 ? configuration.amplitude : -configuration.amplitude
        }
    }

    private static let maximumLengthFeedbackMasks: [Int: UInt32] = [
        2: 0x0003,
        3: 0x0006,
        4: 0x000C,
        5: 0x0014,
        6: 0x0030,
        7: 0x0060,
        8: 0x00B8,
        9: 0x0110,
        10: 0x0240,
        11: 0x0500,
        12: 0x0E08,
        13: 0x1C80,
        14: 0x3802,
        15: 0x6000,
        16: 0xB400
    ]

    private func bandLimitedNoise(
        _ configuration: TestSignalConfiguration,
        frameCount: Int
    ) throws -> [Float] {
        var generator = SplitMix64(state: configuration.deterministicSeed)
        var whiteNoise = (0..<frameCount).map { _ in generator.nextSignedFloat() }
        guard frameCount >= 3 else {
            scaleToPeak(&whiteNoise, peak: configuration.amplitude)
            return whiteNoise
        }

        let maximumTapCount = min(129, frameCount.isMultiple(of: 2) ? frameCount - 1 : frameCount)
        let tapCount = max(3, maximumTapCount)
        let half = tapCount / 2
        let low = configuration.startFrequencyHertz / configuration.sampleRate.hertz
        let high = configuration.endFrequencyHertz / configuration.sampleRate.hertz
        var coefficients = [Float](repeating: 0, count: tapCount)

        for index in 0..<tapCount {
            let offset = index - half
            let ideal: Double
            if offset == 0 {
                ideal = 2 * (high - low)
            } else {
                let position = Double(offset)
                ideal = (
                    sin(2 * Double.pi * high * position) -
                    sin(2 * Double.pi * low * position)
                ) / (Double.pi * position)
            }
            let window = 0.5 + 0.5 * cos(Double.pi * Double(offset) / Double(half))
            coefficients[index] = Float(ideal * window)
        }

        let (paddedFrameCount, paddedOverflow) = frameCount.addingReportingOverflow(tapCount - 1)
        guard !paddedOverflow else { throw SignalGenerationError.sampleCountOverflow }
        var padded = [Float](repeating: 0, count: paddedFrameCount)
        padded.replaceSubrange(half..<(half + frameCount), with: whiteNoise)
        var filtered = [Float](repeating: 0, count: frameCount)
        padded.withUnsafeBufferPointer { input in
            coefficients.withUnsafeBufferPointer { filter in
                filtered.withUnsafeMutableBufferPointer { output in
                    guard let inputBase = input.baseAddress,
                          let filterBase = filter.baseAddress,
                          let outputBase = output.baseAddress else { return }
                    vDSP_conv(
                        inputBase,
                        1,
                        filterBase,
                        1,
                        outputBase,
                        1,
                        vDSP_Length(frameCount),
                        vDSP_Length(tapCount)
                    )
                }
            }
        }
        scaleToPeak(&filtered, peak: configuration.amplitude)
        return filtered
    }

    private func scaleToPeak(_ samples: inout [Float], peak targetPeak: Float) {
        guard !samples.isEmpty else { return }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 0 else { return }
        var multiplier = targetPeak / peak
        samples.withUnsafeMutableBufferPointer { storage in
            guard let baseAddress = storage.baseAddress else { return }
            vDSP_vsmul(
                baseAddress,
                1,
                &multiplier,
                baseAddress,
                1,
                vDSP_Length(storage.count)
            )
        }
    }

    private func applyRaisedCosineFades(
        to samples: inout [Float],
        fadeInFrames: Int,
        fadeOutFrames: Int
    ) {
        for frame in 0..<fadeInFrames {
            let gain: Float
            if fadeInFrames == 1 {
                gain = 0
            } else {
                gain = Float(0.5 - 0.5 * cos(Double.pi * Double(frame) / Double(fadeInFrames - 1)))
            }
            samples[frame] *= gain
        }
        for offset in 0..<fadeOutFrames {
            let frame = samples.count - fadeOutFrames + offset
            let gain: Float
            if fadeOutFrames == 1 {
                gain = 0
            } else {
                gain = Float(0.5 + 0.5 * cos(Double.pi * Double(offset) / Double(fadeOutFrames - 1)))
            }
            samples[frame] *= gain
        }
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextSignedFloat() -> Float {
        let unit = Double(next() >> 11) * 0x1.0p-53
        return Float(unit * 2 - 1)
    }
}

/// Compatibility entry point retained for existing callers. New measurement
/// code should use TestSignalGenerator and TestSignalConfiguration.
public struct SineSignalGenerator: Sendable {
    public init() {}

    public func generate(
        frequencyHertz: Double,
        amplitude: Float = 0.5,
        duration: DurationSeconds,
        sampleRate: SampleRate
    ) throws -> AudioSampleBuffer {
        guard frequencyHertz.isFinite,
              frequencyHertz > 0,
              frequencyHertz <= sampleRate.hertz / 2,
              amplitude.isFinite,
              (0...1).contains(amplitude) else {
            throw MeasurementError.invalidConfiguration(
                ErrorContext(diagnosticMessage: "Frequency or amplitude is outside the valid range.")
            )
        }

        let exactFrameCount = duration.value * sampleRate.hertz
        let roundedFrameCount = exactFrameCount.rounded()
        guard exactFrameCount.isFinite,
              roundedFrameCount >= 1,
              roundedFrameCount < Double(Int.max) else {
            throw MeasurementError.invalidConfiguration(
                ErrorContext(diagnosticMessage: "Duration must contain a representable positive sample count.")
            )
        }
        let frameCount = Int(roundedFrameCount)
        let phaseStep = 2 * Double.pi * frequencyHertz / sampleRate.hertz
        let samples = (0..<frameCount).map { index in
            amplitude * Float(sin(Double(index) * phaseStep))
        }
        return try AudioSampleBuffer(
            samples: samples,
            format: AudioFormatDescriptor(
                sampleRate: sampleRate,
                channelCount: 1,
                bitDepth: 32,
                isInterleaved: false
            )
        )
    }
}
