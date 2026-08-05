import AudioLinkCore
import Foundation
import Testing
@testable import AudioLinkDSP

private func pcmBuffer(samples: [Float], channels: Int = 1) throws -> AudioSampleBuffer {
    try AudioSampleBuffer(
        samples: samples,
        format: AudioFormatDescriptor(
            sampleRate: .hz48000,
            channelCount: channels,
            bitDepth: 32,
            isInterleaved: false
        )
    )
}

@Test func pcmPropertiesReportFramesDurationPeakAndRMS() throws {
    let buffer = try pcmBuffer(samples: [Float(3.0 / 5.0), Float(4.0 / 5.0)])

    #expect(buffer.frameCount == 2)
    #expect(buffer.sampleCount == SampleCount(rawValue: 2))
    #expect(abs(buffer.duration.value - 2.0 / 48_000) < 1e-12)
    #expect(abs(buffer.peakMagnitude - 0.8) < 1e-6)
    #expect(abs(buffer.rootMeanSquare - Float(sqrt(0.5))) < 1e-6)
    #expect(buffer.isPlanar)
}

@Test func gainNormalizationAndFadesAreSafe() throws {
    var buffer = try pcmBuffer(samples: [0.25, -0.5, 0.5, -0.25])
    try buffer.applyGain(0.5)
    #expect(buffer.samples == [0.125, -0.25, 0.25, -0.125])

    try buffer.normalize(toPeak: 0.8)
    #expect(abs(buffer.peakMagnitude - 0.8) < 1e-6)

    try buffer.applyFades(fadeInFrames: 2, fadeOutFrames: 2)
    #expect(buffer.samples.first == 0)
    #expect(buffer.samples.last == 0)
    #expect(buffer.samples[1] != 0)
    #expect(buffer.samples[2] != 0)
}

@Test func planarSilenceConcatenationPreservesChannelOrder() throws {
    let stereo = try pcmBuffer(samples: [1, 2, 3, 10, 20, 30], channels: 2)
    let padded = try stereo.addingSilence(preFrames: 2, postFrames: 1)

    #expect(padded.frameCount == 6)
    #expect(padded.samples == [0, 0, 1, 2, 3, 0, 0, 0, 10, 20, 30, 0])
}

@Test func monoStereoRoundTripUsesPlanarChannels() throws {
    let mono = try pcmBuffer(samples: [0.1, -0.2, 0.3])
    let stereo = try mono.convertedToStereo()
    let roundTrip = try stereo.convertedToMono()

    #expect(stereo.channelCount == 2)
    #expect(stereo.samples == [0.1, -0.2, 0.3, 0.1, -0.2, 0.3])
    #expect(roundTrip == mono)
}

@Test func valueCopiesShareLargeSampleStorageUntilMutation() throws {
    let original = try pcmBuffer(samples: [Float](repeating: 0.25, count: 1_000_000))
    var copy = original
    let originalAddress = original.withUnsafeSamples { storage in
        storage.baseAddress.map { UInt(bitPattern: $0) }
    }
    let copiedAddress = copy.withUnsafeSamples { storage in
        storage.baseAddress.map { UInt(bitPattern: $0) }
    }
    let unchanged = try original.addingSilence(preFrames: 0, postFrames: 0)
    let unchangedAddress = unchanged.withUnsafeSamples { storage in
        storage.baseAddress.map { UInt(bitPattern: $0) }
    }

    #expect(originalAddress == copiedAddress)
    #expect(originalAddress == unchangedAddress)
    try copy.applyGain(2)
    #expect(original.samples[0] == 0.25)
    #expect(copy.samples[0] == 0.5)
}

@Test func invalidPCMOperationsThrowStructuredErrors() throws {
    #expect(throws: AudioSampleBufferError.self) {
        try AudioSampleBuffer(
            samples: [0, 0, 0],
            format: AudioFormatDescriptor(
                sampleRate: .hz48000,
                channelCount: 2,
                bitDepth: 32,
                isInterleaved: false
            )
        )
    }
    #expect(throws: AudioSampleBufferError.self) {
        try pcmBuffer(samples: [.nan])
    }
    #expect(throws: AudioSampleBufferError.self) {
        var buffer = try pcmBuffer(samples: [1])
        try buffer.applyGain(.infinity)
    }
}
