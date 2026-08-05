import AudioLinkCore
import Foundation
import Testing
@testable import AudioLinkDSP

@Test func channelSelectionAndStereoDownmixAreExplicit() async throws {
    let imported = try importedFixture(
        samples: [0.2, 0.4, 0.6, -0.2, -0.4, -0.6],
        channels: 2
    )
    let selected = try await AudioPreprocessor().process(
        imported,
        configuration: PreprocessingConfiguration(selectedChannel: 1)
    )
    let downmixed = try await AudioPreprocessor().process(
        imported,
        configuration: PreprocessingConfiguration(downmixToMono: true)
    )

    #expect(selected.audio.samples == [-0.2, -0.4, -0.6])
    #expect(selected.channelCount == 1)
    #expect(downmixed.audio.samples.allSatisfy { abs($0) < 1e-7 })
    #expect(downmixed.preprocessingLog.count == 1)
}

@Test func removingDCOffsetProducesNearZeroMeanAndLogsOffsets() async throws {
    let imported = try importedFixture(samples: [0.2, 0.4, 0.6], channels: 1)
    let processed = try await AudioPreprocessor().process(
        imported,
        configuration: PreprocessingConfiguration(removeDCOffset: true)
    )

    #expect(abs(processed.dcOffset) < 1e-7)
    #expect(abs(processed.audio.samples[0] + 0.2) < 1e-6)
    #expect(abs(processed.audio.samples[1]) < 1e-6)
    #expect(abs(processed.audio.samples[2] - 0.2) < 1e-6)
    guard case let .removedDCOffset(offsets) = processed.preprocessingLog.first?.operation else {
        Issue.record("Expected a DC-removal log entry")
        return
    }
    #expect(abs(offsets[0] - 0.4) < 1e-6)
}

@Test func peakAndRMSNormalizationReachExplicitTargets() async throws {
    let peakSource = try importedFixture(samples: [0.1, -0.2], channels: 1)
    let peakNormalized = try await AudioPreprocessor().process(
        peakSource,
        configuration: PreprocessingConfiguration(peakNormalizationTarget: 0.8)
    )
    #expect(abs(peakNormalized.peakMagnitude - 0.8) < 1e-6)
    #expect(peakNormalized.audio.samples == [0.4, -0.8])

    let rmsSource = try importedFixture(samples: [0.1, -0.1], channels: 1)
    let rmsNormalized = try await AudioPreprocessor().process(
        rmsSource,
        configuration: PreprocessingConfiguration(rmsNormalizationTarget: 0.2)
    )
    #expect(abs(rmsNormalized.rootMeanSquare - 0.2) < 1e-6)
    #expect(abs(rmsNormalized.peakMagnitude - 0.2) < 1e-6)
}

@Test func leadingAndTrailingSilenceTrimExactRanges() async throws {
    let imported = try importedFixture(
        samples: [0, 0, 0.001, 0.2, -0.2, 0.001, 0, 0],
        channels: 1
    )
    let trim = SilenceTrimmingConfiguration(threshold: 0.01)
    let processed = try await AudioPreprocessor().process(
        imported,
        configuration: PreprocessingConfiguration(
            trimLeadingSilence: trim,
            trimTrailingSilence: trim
        )
    )

    #expect(processed.audio.samples == [0.2, -0.2])
    #expect(processed.preprocessingLog.count == 2)
    #expect(processed.preprocessingLog[0].inputFrameCount == 8)
    #expect(processed.preprocessingLog[0].outputFrameCount == 5)
    #expect(processed.preprocessingLog[1].inputFrameCount == 5)
    #expect(processed.preprocessingLog[1].outputFrameCount == 2)
}

@Test func stereoSilenceTrimmingChecksEveryChannel() async throws {
    let imported = try importedFixture(
        samples: [0, 0, 0.2, 0, 0, 0, 0.3, 0, 0, 0],
        channels: 2
    )
    let trim = SilenceTrimmingConfiguration(threshold: 0.01)
    let processed = try await AudioPreprocessor().process(
        imported,
        configuration: PreprocessingConfiguration(
            trimLeadingSilence: trim,
            trimTrailingSilence: trim
        )
    )

    #expect(processed.frameCount == 2)
    #expect(processed.audio.samples == [0, 0.2, 0.3, 0])
}

@Test func highPassSuppressesConstantDrift() async throws {
    let imported = try importedFixture(
        samples: [Float](repeating: 0.5, count: 4_800),
        channels: 1
    )
    let processed = try await AudioPreprocessor().process(
        imported,
        configuration: PreprocessingConfiguration(
            highPassFilter: HighPassFilterConfiguration(cutoffFrequencyHertz: 100)
        )
    )

    #expect(abs(processed.audio.samples.last ?? 1) < 1e-4)
    #expect(processed.rootMeanSquare < imported.rootMeanSquare * 0.2)
}

@Test func resamplingPreservesDurationWithinOneOutputFrame() async throws {
    let frameCount = 4_410
    let samples = (0..<frameCount).map { frame in
        Float(sin(2 * Double.pi * 1_000 * Double(frame) / 44_100)) * 0.5
    }
    let imported = try importedFixture(
        samples: samples,
        channels: 1,
        sampleRate: .hz44100
    )
    let processed = try await AudioPreprocessor().process(
        imported,
        configuration: PreprocessingConfiguration(targetSampleRate: .hz48000)
    )

    #expect(abs(processed.frameCount - 4_800) <= 1)
    #expect(abs(processed.duration.value - imported.duration.value) <= 1.0 / 48_000)
    #expect(processed.wasResampled)
    guard case let .resampled(sourceRate, destinationRate, inputFrames, outputFrames) =
        processed.preprocessingLog.first?.operation else {
        Issue.record("Expected a resampling log entry")
        return
    }
    #expect(sourceRate == .hz44100)
    #expect(destinationRate == .hz48000)
    #expect(inputFrames == 4_410)
    #expect(outputFrames == processed.frameCount)
}

@Test func stereoResamplingPreservesChannelLayoutAndDuration() async throws {
    let frameCount = 882
    let left = (0..<frameCount).map { frame in
        Float(sin(2 * Double.pi * 500 * Double(frame) / 44_100)) * 0.4
    }
    let right = (0..<frameCount).map { frame in
        Float(sin(2 * Double.pi * 1_500 * Double(frame) / 44_100)) * 0.4
    }
    let imported = try importedFixture(
        samples: left + right,
        channels: 2,
        sampleRate: .hz44100
    )
    let processed = try await AudioPreprocessor().process(
        imported,
        configuration: PreprocessingConfiguration(targetSampleRate: .hz48000)
    )

    #expect(processed.channelCount == 2)
    #expect(processed.frameCount == 960)
    #expect(processed.audio.samples.count == 1_920)
    #expect(abs(processed.duration.value - 0.02) <= 1.0 / 48_000)
    #expect(
        Array(processed.audio.samples[0..<processed.frameCount]) !=
            Array(processed.audio.samples[processed.frameCount..<processed.audio.samples.count])
    )
}

@Test func polarityAndSafeGainAreLoggedInOrder() async throws {
    let imported = try importedFixture(samples: [0.1, -0.2], channels: 1)
    let processed = try await AudioPreprocessor().process(
        imported,
        configuration: PreprocessingConfiguration(invertPolarity: true, gain: 2)
    )

    #expect(processed.audio.samples == [-0.2, 0.4])
    #expect(processed.preprocessingLog.count == 2)
    #expect(processed.preprocessingLog[0].sequence == 0)
    #expect(processed.preprocessingLog[1].sequence == 1)
    #expect(processed.preprocessingSummary == ["Inverted polarity", "Applied linear gain 2.0"])
    let encodedLog = try JSONEncoder().encode(processed.preprocessingLog)
    #expect(
        try JSONDecoder().decode([PreprocessingLogEntry].self, from: encodedLog) ==
            processed.preprocessingLog
    )
}

@Test func noPreprocessingLeavesAudioAndLogUnchanged() async throws {
    let imported = try importedFixture(samples: [0.1, -0.2], channels: 1)
    let processed = try await AudioPreprocessor().process(
        imported,
        configuration: .none
    )

    #expect(processed == imported)
    #expect(processed.preprocessingLog.isEmpty)
    #expect(!processed.wasResampled)
}

@Test func invalidOrClippingPreprocessingIsRejected() async throws {
    let stereo = try importedFixture(samples: [0.9, 0.1, 0.9, 0.1], channels: 2)

    await #expect(throws: AudioPreprocessingError.conflictingChannelOperations) {
        try await AudioPreprocessor().process(
            stereo,
            configuration: PreprocessingConfiguration(selectedChannel: 0, downmixToMono: true)
        )
    }
    await #expect(throws: AudioPreprocessingError.conflictingNormalizations) {
        try await AudioPreprocessor().process(
            stereo,
            configuration: PreprocessingConfiguration(
                peakNormalizationTarget: 0.8,
                rmsNormalizationTarget: 0.2
            )
        )
    }
    await #expect(throws: AudioPreprocessingError.self) {
        try await AudioPreprocessor().process(
            stereo,
            configuration: PreprocessingConfiguration(gain: 2)
        )
    }
    await #expect(throws: AudioPreprocessingError.self) {
        try await AudioPreprocessor().process(
            stereo,
            configuration: PreprocessingConfiguration(rmsNormalizationTarget: 0.9)
        )
    }
}

@Test func preprocessingSupportsCancellation() async throws {
    let imported = try importedFixture(
        samples: [Float](repeating: 0.5, count: 800_000),
        channels: 1
    )
    let progressStream = AsyncStream<AudioPreprocessingProgress>.makeStream()
    let processingTask = Task {
        try await AudioPreprocessor().process(
            imported,
            configuration: PreprocessingConfiguration(
                highPassFilter: HighPassFilterConfiguration(cutoffFrequencyHertz: 20)
            )
        ) { progress in
            progressStream.continuation.yield(progress)
        }
    }

    for await progress in progressStream.stream {
        if progress.completedOperationCount == 0 {
            processingTask.cancel()
            progressStream.continuation.finish()
            break
        }
    }

    await #expect(throws: AudioPreprocessingError.cancelled) {
        try await processingTask.value
    }
}

private func importedFixture(
    samples: [Float],
    channels: Int,
    sampleRate: SampleRate = .hz48000
) throws -> ImportedAudioFile {
    let audio = try testBuffer(samples: samples, channels: channels, sampleRate: sampleRate)
    return ImportedAudioFile(
        fileURL: URL(fileURLWithPath: "/tmp/fixture.wav"),
        fileName: "fixture.wav",
        originalFormat: AudioFileFormatDescription(
            container: .wav,
            encoding: .ieeeFloat,
            sampleRate: sampleRate,
            channelCount: channels,
            bitDepth: 32,
            isInterleaved: true,
            isBigEndian: false,
            formatIdentifier: "WAVE_FORMAT_IEEE_FLOAT"
        ),
        audio: audio,
        analysis: AudioMetricsAnalyzer().analyze(audio)
    )
}
