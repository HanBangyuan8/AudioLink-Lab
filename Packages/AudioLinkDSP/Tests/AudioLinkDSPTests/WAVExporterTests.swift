import AVFoundation
import AudioLinkCore
import Foundation
import Testing
@testable import AudioLinkDSP

@Test func twoSecondReferenceSweepExportsAsStandardPCM16WAV() throws {
    let generated = try TestSignalGenerator().generate(
        configuration: TestSignalConfiguration(
            kind: .logarithmicSweep,
            sampleRate: .hz48000,
            duration: try DurationSeconds(2),
            startFrequencyHertz: 20,
            endFrequencyHertz: 20_000,
            amplitude: 0.8,
            fadeIn: try DurationSeconds(0.01),
            fadeOut: try DurationSeconds(0.01)
        )
    )
    let wav = try WAVExporter().data(for: generated.audio)

    #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
    #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
    #expect(wav.count == 44 + 96_000 * 2)
}

@Test func exportedWAVCanBeOpenedByAVFoundation() throws {
    let generated = try TestSignalGenerator().generate(
        configuration: TestSignalConfiguration(
            kind: .shortChirp,
            sampleRate: .hz44100,
            duration: try DurationSeconds(0.1),
            startFrequencyHertz: 200,
            endFrequencyHertz: 8_000,
            channelCount: 2
        )
    )
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioLinkDSP-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    try WAVExporter().write(generated.audio, to: url)
    let audioFile = try AVAudioFile(forReading: url)

    #expect(audioFile.length == 4_410)
    #expect(audioFile.fileFormat.channelCount == 2)
    #expect(audioFile.fileFormat.sampleRate == 44_100)
}

@Test func floatWAVUsesIEEEFloatFormatAndExpectedSize() throws {
    let buffer = try AudioSampleBuffer(
        samples: [0, 0.5, -0.5, 1],
        format: AudioFormatDescriptor(
            sampleRate: .hz96000,
            channelCount: 1,
            bitDepth: 32,
            isInterleaved: false
        )
    )
    let wav = try WAVExporter().data(for: buffer, encoding: .ieeeFloat32)

    #expect(wav.count == 44 + 4 * 4)
    #expect(wav[20] == 3)
    #expect(wav[21] == 0)
}
