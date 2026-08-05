import AVFoundation
import AudioLinkCore
import AudioToolbox
import Foundation
import Testing
@testable import AudioLinkDSP

@Test func wavIntegerAndFloatDepthsDecodeConsistently() async throws {
    let sourceSamples: [Float] = [-1, -0.75, -0.25, 0, 0.25, 0.75, 1]
    let source = try testBuffer(samples: sourceSamples, channels: 1, sampleRate: .hz48000)
    let cases: [(WAVEncoding, Int, Float)] = [
        (.pcmInt16, 16, 1.0 / 32_767),
        (.pcmInt24, 24, 1.0 / 8_388_607),
        (.pcmInt32, 32, 1e-7),
        (.ieeeFloat32, 32, 0)
    ]

    for (encoding, bitDepth, tolerance) in cases {
        let url = try temporaryWAV(buffer: source, encoding: encoding)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try await AudioFileImporter().importFile(at: url)

        #expect(imported.originalFormat.container == .wav)
        #expect(imported.originalFormat.bitDepth == bitDepth)
        #expect(
            imported.originalFormat.encoding ==
                (encoding == .ieeeFloat32 ? .ieeeFloat : .signedIntegerPCM)
        )
        #expect(imported.frameCount == sourceSamples.count)
        #expect(imported.channelCount == 1)
        #expect(imported.internalFormat.bitDepth == 32)
        #expect(!imported.internalFormat.isInterleaved)
        #expect(imported.clippingSampleCount == 2)
        for (actual, expected) in zip(imported.audio.samples, sourceSamples) {
            #expect(abs(actual - expected) <= tolerance)
        }
    }
}

@Test func everyBaselineWAVEncodingSupportsInterleavedStereo() async throws {
    let planar: [Float] = [0.1, 0.2, 0.3, -0.1, -0.2, -0.3]
    let source = try testBuffer(samples: planar, channels: 2, sampleRate: .hz44100)
    let cases: [(WAVEncoding, Float)] = [
        (.pcmInt16, 1.0 / 32_767),
        (.pcmInt24, 1.0 / 8_388_607),
        (.pcmInt32, 1e-7),
        (.ieeeFloat32, 0)
    ]
    for (encoding, tolerance) in cases {
        let url = try temporaryWAV(buffer: source, encoding: encoding)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try await AudioFileImporter().importFile(at: url)

        #expect(imported.originalFormat.isInterleaved)
        #expect(imported.channelCount == 2)
        #expect(imported.frameCount == 3)
        for (actual, expected) in zip(imported.audio.samples, planar) {
            #expect(abs(actual - expected) <= tolerance)
        }
    }
}

@Test func promptTwoGeneratedSweepRoundTripsThroughImporter() async throws {
    let generated = try TestSignalGenerator().generate(
        configuration: TestSignalConfiguration(
            kind: .logarithmicSweep,
            sampleRate: .hz48000,
            duration: try DurationSeconds(0.05),
            startFrequencyHertz: 20,
            endFrequencyHertz: 20_000,
            amplitude: 0.8
        )
    )
    let url = try temporaryWAV(buffer: generated.audio, encoding: .pcmInt16)
    defer { try? FileManager.default.removeItem(at: url) }

    let imported = try await AudioFileImporter().importFile(at: url)

    #expect(imported.frameCount == 2_400)
    #expect(imported.sampleRate == .hz48000)
    #expect(imported.peakMagnitude <= 0.8 + 1.0 / 32_767)
    #expect(imported.rootMeanSquare > 0)
}

@Test func importAnalysisDetectsFullScaleClippingAndDCOffset() async throws {
    let source = try testBuffer(samples: [-1, 1, 0.5, 0.5], channels: 1, sampleRate: .hz48000)
    let url = try temporaryWAV(buffer: source, encoding: .ieeeFloat32)
    defer { try? FileManager.default.removeItem(at: url) }

    let imported = try await AudioFileImporter().importFile(at: url)

    #expect(imported.clippingSampleCount == 2)
    #expect(imported.peakMagnitude == 1)
    #expect(abs(imported.dcOffset - 0.25) < 1e-7)
    #expect(abs(imported.rootMeanSquare - Float(sqrt(0.625))) < 1e-6)
}

@Test func emptyAndCorruptedWAVsReturnStructuredErrors() async throws {
    let emptyURL = temporaryURL(extension: "wav")
    let corruptURL = temporaryURL(extension: "wav")
    try Data().write(to: emptyURL)
    try Data("RIFF\u{04}\0\0\0WAVE".utf8).write(to: corruptURL)
    defer {
        try? FileManager.default.removeItem(at: emptyURL)
        try? FileManager.default.removeItem(at: corruptURL)
    }

    await #expect(throws: AudioImportError.self) {
        try await AudioFileImporter().importFile(at: emptyURL)
    }
    await #expect(throws: AudioImportError.self) {
        try await AudioFileImporter().importFile(at: corruptURL)
    }
}

@Test func configuredImportLimitRejectsAudioBeforeLargeAllocation() async throws {
    let source = try testBuffer(samples: [0.1, 0.2], channels: 1, sampleRate: .hz48000)
    let url = try temporaryWAV(buffer: source, encoding: .pcmInt16)
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: AudioImportError.inputTooLarge(maximumFrames: 1)) {
        try await AudioFileImporter(limits: AudioImportLimits(maximumDecodedFrames: 1, maximumDecodedBytes: 64)).importFile(at: url)
    }
}

@Test func importerErrorDiagnosticsDoNotExposeAbsoluteFilePaths() async throws {
    let url = temporaryURL(extension: "wav")
    let error = await #expect(throws: AudioImportError.self) {
        try await AudioFileImporter().importFile(at: url)
    }
    #expect(error?.debugDescription.contains(url.path) == false)
    #expect(error?.debugDescription.contains(url.lastPathComponent) == true)
}

@Test func oneFrameWAVImportsWithoutBoundsErrors() async throws {
    let source = try testBuffer(samples: [0.25], channels: 1, sampleRate: .hz96000)
    let url = try temporaryWAV(buffer: source, encoding: .pcmInt32)
    defer { try? FileManager.default.removeItem(at: url) }

    let imported = try await AudioFileImporter().importFile(at: url)

    #expect(imported.frameCount == 1)
    #expect(imported.duration.value == 1.0 / 96_000)
    #expect(abs(imported.audio.samples[0] - 0.25) < 1e-7)
}

@Test func avFoundationFallbackIsVerifiedForAIFFCAFAndM4A() async throws {
    let cases: [(String, [String: Any], AudioFileContainer, AudioFileSampleEncoding)] = [
        (
            "aiff",
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: true
            ],
            .aiff,
            .signedIntegerPCM
        ),
        (
            "caf",
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false
            ],
            .caf,
            .ieeeFloat
        ),
        (
            "m4a",
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ],
            .m4a,
            .compressed
        )
    ]

    for (fileExtension, settings, expectedContainer, expectedEncoding) in cases {
        let url = try avFoundationFixture(extension: fileExtension, settings: settings)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try await AudioFileImporter().importFile(at: url)

        #expect(imported.originalFormat.container == expectedContainer)
        #expect(imported.originalFormat.encoding == expectedEncoding)
        #expect(imported.frameCount == 2_205)
        #expect(imported.channelCount == 1)
        #expect(imported.sampleRate == .hz44100)
        #expect(imported.metadata["decoder"] == "AVFoundation")
        #expect(imported.rootMeanSquare > 0.2)
    }
}

@Test func asynchronousImportReportsProgressAndSupportsCancellation() async throws {
    let source = try testBuffer(
        samples: [Float](repeating: 0.125, count: 600_000),
        channels: 1,
        sampleRate: .hz48000
    )
    let url = try temporaryWAV(buffer: source, encoding: .pcmInt16)
    defer { try? FileManager.default.removeItem(at: url) }
    let progressStream = AsyncStream<AudioImportProgress>.makeStream()
    let importTask = Task {
        try await AudioFileImporter().importFile(at: url) { progress in
            progressStream.continuation.yield(progress)
            if progress.phase == .decoding { Thread.sleep(forTimeInterval: 0.0005) }
        }
    }

    for await progress in progressStream.stream {
        if progress.phase == .decoding, progress.completedFrames > 0 {
            importTask.cancel()
            progressStream.continuation.finish()
            break
        }
    }

    await #expect(throws: AudioImportError.cancelled) {
        try await importTask.value
    }
}

@MainActor
@Test func importingFromMainActorKeepsDecodeWorkOffMainThread() async throws {
    let source = try testBuffer(
        samples: [Float](repeating: 0.125, count: 20_000),
        channels: 1,
        sampleRate: .hz48000
    )
    let url = try temporaryWAV(buffer: source, encoding: .pcmInt16)
    defer { try? FileManager.default.removeItem(at: url) }
    let observation = ThreadObservation()

    _ = try await AudioFileImporter().importFile(at: url) { _ in
        observation.record(isMainThread: Thread.isMainThread)
    }

    #expect(observation.callbackCount > 0)
    #expect(!observation.observedMainThread)
}

func testBuffer(
    samples: [Float],
    channels: Int,
    sampleRate: SampleRate
) throws -> AudioSampleBuffer {
    try AudioSampleBuffer(
        samples: samples,
        format: AudioFormatDescriptor(
            sampleRate: sampleRate,
            channelCount: channels,
            bitDepth: 32,
            isInterleaved: false
        )
    )
}

func temporaryWAV(
    buffer: AudioSampleBuffer,
    encoding: WAVEncoding
) throws -> URL {
    let url = temporaryURL(extension: "wav")
    try WAVExporter().write(buffer, to: url, encoding: encoding)
    return url
}

func temporaryURL(extension fileExtension: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioLinkDSP-\(UUID().uuidString)")
        .appendingPathExtension(fileExtension)
}

private enum FixtureError: Error {
    case couldNotCreateFormat
    case couldNotCreateBuffer
}

private final class ThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var sawMainThread = false

    var callbackCount: Int {
        lock.withLock { count }
    }

    var observedMainThread: Bool {
        lock.withLock { sawMainThread }
    }

    func record(isMainThread: Bool) {
        lock.withLock {
            count += 1
            sawMainThread = sawMainThread || isMainThread
        }
    }
}

private func avFoundationFixture(
    extension fileExtension: String,
    settings: [String: Any]
) throws -> URL {
    let url = temporaryURL(extension: fileExtension)
    try writeAVFoundationFixture(to: url, settings: settings)
    return url
}

private func writeAVFoundationFixture(
    to url: URL,
    settings: [String: Any]
) throws {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 1,
        interleaved: false
    ) else {
        throw FixtureError.couldNotCreateFormat
    }
    let file = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let frameCount: AVAudioFrameCount = 2_205
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          let channel = buffer.floatChannelData?[0] else {
        throw FixtureError.couldNotCreateBuffer
    }
    buffer.frameLength = frameCount
    for frame in 0..<Int(frameCount) {
        channel[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / 44_100)) * 0.5
    }
    try file.write(from: buffer)
}
