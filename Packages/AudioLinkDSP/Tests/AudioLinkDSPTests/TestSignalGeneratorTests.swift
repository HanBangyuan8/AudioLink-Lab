import AudioLinkCore
import Foundation
import Testing
@testable import AudioLinkDSP

private func signalConfiguration(
    kind: SignalKind,
    sampleRate: SampleRate = .hz48000,
    duration: Double = 0.05,
    startFrequency: Double = 100,
    endFrequency: Double = 10_000,
    amplitude: Float = 0.5,
    preRoll: Double = 0,
    postRoll: Double = 0,
    fadeIn: Double = 0,
    fadeOut: Double = 0,
    channels: Int = 1,
    seed: UInt64 = 42,
    direction: SweepDirection = .ascending,
    polarity: SignalPolarity = .positive,
    mlsOrder: Int = 8
) throws -> TestSignalConfiguration {
    TestSignalConfiguration(
        kind: kind,
        sampleRate: sampleRate,
        duration: try DurationSeconds(duration),
        startFrequencyHertz: startFrequency,
        endFrequencyHertz: endFrequency,
        amplitude: amplitude,
        preRollSilence: try DurationSeconds(preRoll),
        postRollSilence: try DurationSeconds(postRoll),
        fadeIn: try DurationSeconds(fadeIn),
        fadeOut: try DurationSeconds(fadeOut),
        channelCount: channels,
        deterministicSeed: seed,
        sweepDirection: direction,
        polarity: polarity,
        maximumLengthSequenceOrder: mlsOrder
    )
}

@Test func everySupportedSignalKindGeneratesFinitePCM() throws {
    let generator = TestSignalGenerator()
    for kind in SignalKind.allCases {
        let result = try generator.generate(configuration: signalConfiguration(kind: kind))
        #expect(result.audio.frameCount == 2_400)
        #expect(result.audio.samples.allSatisfy { $0.isFinite })
        #expect(result.audio.peakMagnitude <= 0.5 + Float.ulpOfOne)
    }
}

@Test func durationPaddingAndChannelsProduceExactFrameCounts() throws {
    let configuration = try signalConfiguration(
        kind: .logarithmicSweep,
        duration: 2,
        startFrequency: 20,
        endFrequency: 20_000,
        preRoll: 0.01,
        postRoll: 0.02,
        channels: 2
    )
    let result = try TestSignalGenerator().generate(configuration: configuration)

    #expect(result.activeFrameRange == 480..<96_480)
    #expect(result.audio.frameCount == 97_440)
    #expect(result.audio.samples.count == 194_880)
    #expect(result.activeSampleCount == SampleCount(rawValue: 96_000))
    #expect(abs(result.activeDuration.value - 2) < 1e-12)
}

@Test func silencePaddingIsExactlyZeroOnEveryChannel() throws {
    let result = try TestSignalGenerator().generate(
        configuration: signalConfiguration(
            kind: .maximumLengthSequence,
            duration: 0.01,
            preRoll: 0.002,
            postRoll: 0.003,
            channels: 2
        )
    )

    for channel in 0..<2 {
        for frame in 0..<result.activeFrameRange.lowerBound {
            #expect(result.audio.sample(frame: frame, channel: channel) == 0)
        }
        for frame in result.activeFrameRange.upperBound..<result.audio.frameCount {
            #expect(result.audio.sample(frame: frame, channel: channel) == 0)
        }
    }
}

@Test func raisedCosineFadesHaveExactEndpoints() throws {
    let result = try TestSignalGenerator().generate(
        configuration: signalConfiguration(
            kind: .maximumLengthSequence,
            duration: 0.02,
            amplitude: 0.75,
            fadeIn: 0.002,
            fadeOut: 0.002
        )
    )
    let fadeFrames = 96
    let lastFrame = result.audio.frameCount - 1

    #expect(result.audio.samples[0] == 0)
    #expect(abs(abs(result.audio.samples[fadeFrames - 1]) - 0.75) < 1e-6)
    #expect(abs(abs(result.audio.samples[lastFrame - fadeFrames + 1]) - 0.75) < 1e-6)
    #expect(result.audio.samples[lastFrame] == 0)
}

@Test func deterministicNoiseUsesItsSeed() throws {
    let generator = TestSignalGenerator()
    let first = try generator.generate(
        configuration: signalConfiguration(kind: .bandLimitedNoise, seed: 123)
    )
    let repeated = try generator.generate(
        configuration: signalConfiguration(kind: .bandLimitedNoise, seed: 123)
    )
    let different = try generator.generate(
        configuration: signalConfiguration(kind: .bandLimitedNoise, seed: 124)
    )

    #expect(first.audio.samples == repeated.audio.samples)
    #expect(first.audio.samples != different.audio.samples)
}

@Test func signalConfigurationRoundTripsAndRegeneratesExactly() throws {
    let configuration = try signalConfiguration(
        kind: .bandLimitedNoise,
        duration: 0.02,
        preRoll: 0.001,
        postRoll: 0.002,
        fadeIn: 0.001,
        fadeOut: 0.001,
        channels: 2,
        seed: 0x1234_5678
    )
    let encoded = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(TestSignalConfiguration.self, from: encoded)
    let generator = TestSignalGenerator()

    #expect(decoded == configuration)
    #expect(
        try generator.generate(configuration: decoded) ==
        generator.generate(configuration: configuration)
    )
}

@Test func maximumLengthSequenceIsDeterministicAndRepeatsAfterItsPeriod() throws {
    let sampleRate = try SampleRate(hertz: 1_000)
    let configuration = try signalConfiguration(
        kind: .maximumLengthSequence,
        sampleRate: sampleRate,
        duration: 0.510,
        startFrequency: 100,
        endFrequency: 400,
        seed: 1,
        mlsOrder: 8
    )
    let samples = try TestSignalGenerator().generate(configuration: configuration).audio.samples

    #expect(samples.count == 510)
    #expect(Array(samples[0..<255]) == Array(samples[255..<510]))
    #expect(samples[0..<255].filter { $0 > 0 }.count == 128)
    #expect(samples[0..<255].filter { $0 < 0 }.count == 127)
    #expect(Set(samples).count == 2)
}

@Test func bandLimitedNoiseSuppressesOutOfBandEnergy() throws {
    let result = try TestSignalGenerator().generate(
        configuration: signalConfiguration(
            kind: .bandLimitedNoise,
            duration: 0.25,
            startFrequency: 2_000,
            endFrequency: 6_000,
            seed: 7
        )
    )
    let passband = stride(from: 2_250.0, through: 5_750.0, by: 250).map {
        spectralEnergy(result.audio.samples, frequency: $0, sampleRate: 48_000)
    }.reduce(0, +)
    let lowStopband = stride(from: 250.0, through: 1_250.0, by: 250).map {
        spectralEnergy(result.audio.samples, frequency: $0, sampleRate: 48_000)
    }.reduce(0, +)
    let highStopband = stride(from: 8_000.0, through: 16_000.0, by: 500).map {
        spectralEnergy(result.audio.samples, frequency: $0, sampleRate: 48_000)
    }.reduce(0, +)

    #expect(passband > lowStopband * 20)
    #expect(passband > highStopband * 20)
}

@Test func logarithmicSweepFollowsExpectedFrequencyTrajectory() throws {
    let sampleRate = try SampleRate(hertz: 48_000)
    let duration = 1.0
    let start = 100.0
    let end = 6_400.0
    let result = try TestSignalGenerator().generate(
        configuration: signalConfiguration(
            kind: .logarithmicSweep,
            sampleRate: sampleRate,
            duration: duration,
            startFrequency: start,
            endFrequency: end
        )
    )
    let quarterFrames = result.audio.frameCount / 4
    let firstCrossings = zeroCrossings(in: result.audio.samples[0..<quarterFrames])
    let lastCrossings = zeroCrossings(in: result.audio.samples[(3 * quarterFrames)..<result.audio.frameCount])
    let ratio = log(end / start)
    let expectedFirstCycles = start * duration / ratio * (exp(ratio * 0.25) - 1)
    let expectedLastCycles = start * duration / ratio * (exp(ratio) - exp(ratio * 0.75))

    #expect(abs(Double(firstCrossings) / 2 - expectedFirstCycles) < 1.5)
    #expect(abs(Double(lastCrossings) / 2 - expectedLastCycles) < 1.5)
    #expect(lastCrossings > firstCrossings * 8)
}

@Test func descendingSweepReversesFrequencyProgression() throws {
    let result = try TestSignalGenerator().generate(
        configuration: signalConfiguration(
            kind: .linearSweep,
            duration: 0.5,
            startFrequency: 200,
            endFrequency: 8_000,
            direction: .descending
        )
    )
    let quarter = result.audio.frameCount / 4
    let early = zeroCrossings(in: result.audio.samples[0..<quarter])
    let late = zeroCrossings(in: result.audio.samples[(3 * quarter)..<result.audio.frameCount])
    #expect(early > late * 3)
}

@Test func impulseContainsExactlyOneSampleAtTheDocumentedFrame() throws {
    let result = try TestSignalGenerator().generate(
        configuration: signalConfiguration(
            kind: .impulse,
            duration: 0.01,
            amplitude: 0.8,
            preRoll: 0.002,
            fadeIn: 0.001,
            polarity: .inverted
        )
    )
    let nonzero = result.audio.samples.enumerated().filter { $0.element != 0 }

    #expect(result.impulseFrame == 144)
    #expect(nonzero.count == 1)
    #expect(nonzero.first?.offset == result.impulseFrame)
    #expect(nonzero.first?.element == -0.8)
}

@Test func polarityInversionIsSampleExact() throws {
    let positiveConfiguration = try signalConfiguration(kind: .shortChirp, polarity: .positive)
    let invertedConfiguration = try signalConfiguration(kind: .shortChirp, polarity: .inverted)
    let positive = try TestSignalGenerator().generate(configuration: positiveConfiguration).audio.samples
    let inverted = try TestSignalGenerator().generate(configuration: invertedConfiguration).audio.samples

    #expect(zip(positive, inverted).allSatisfy { $0 == -$1 })
}

@Test func standardMeasurementSampleRatesAllWork() throws {
    for sampleRate in [SampleRate.hz44100, .hz48000, .hz96000] {
        let result = try TestSignalGenerator().generate(
            configuration: signalConfiguration(
                kind: .logarithmicSweep,
                sampleRate: sampleRate,
                duration: 0.01,
                startFrequency: 20,
                endFrequency: 20_000
            )
        )
        #expect(result.audio.frameCount == Int(sampleRate.hertz / 100))
    }
}

@Test func oneSampleSignalsDoNotReadOutsideTheirBuffers() throws {
    for kind in SignalKind.allCases {
        let result = try TestSignalGenerator().generate(
            configuration: signalConfiguration(
                kind: kind,
                duration: 1 / 48_000,
                fadeIn: 0,
                fadeOut: 0
            )
        )
        #expect(result.audio.frameCount == 1)
        #expect(result.audio.samples[0].isFinite)
    }
}

@Test func invalidConfigurationsReturnStructuredErrors() throws {
    let generator = TestSignalGenerator()

    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .linearSweep, startFrequency: -1)
        )
    }
    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .linearSweep, endFrequency: 24_001)
        )
    }
    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .logarithmicSweep, startFrequency: 0)
        )
    }
    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .impulse, amplitude: .infinity)
        )
    }
    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .impulse, amplitude: 1.01)
        )
    }
    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .silence, duration: 0)
        )
    }
    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .linearSweep, duration: 0.01, fadeIn: 0.006, fadeOut: 0.006)
        )
    }
    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .impulse, channels: 0)
        )
    }
    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .maximumLengthSequence, mlsOrder: 17)
        )
    }
    #expect(throws: SignalGenerationError.self) {
        try generator.generate(
            configuration: signalConfiguration(kind: .silence, duration: 1e300)
        )
    }
}

private func zeroCrossings(in samples: ArraySlice<Float>) -> Int {
    guard var previous = samples.first else { return 0 }
    var result = 0
    for sample in samples.dropFirst() {
        if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) {
            result += 1
        }
        previous = sample
    }
    return result
}

private func spectralEnergy(_ samples: [Float], frequency: Double, sampleRate: Double) -> Double {
    let phaseStep = 2 * Double.pi * frequency / sampleRate
    var real = 0.0
    var imaginary = 0.0
    for (index, sample) in samples.enumerated() {
        let phase = phaseStep * Double(index)
        real += Double(sample) * cos(phase)
        imaginary -= Double(sample) * sin(phase)
    }
    return real * real + imaginary * imaginary
}
