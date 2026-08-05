import AudioLinkCore
import Testing
@testable import AudioLinkDSP

@Test func acousticDiagnosticsExplainClippingLowLevelAndPolarity() throws {
    let format = AudioFormatDescriptor(sampleRate: .hz48000, channelCount: 1, bitDepth: 32, isInterleaved: false)
    let reference = try AudioSampleBuffer(samples: [0, 1, 0, 0], format: format)
    let recording = try AudioSampleBuffer(samples: [0, -1, 0.0001, 0], format: format)
    let peak = CorrelationPeak(lag: SampleCount(rawValue: 1), value: -0.9, overlapCount: SampleCount(rawValue: 4))
    let sequence = CorrelationSequence(firstLag: 0, values: [0, -0.9, 0.4, 0])
    let correlation = CorrelationResult(peakOffset: SampleCount(rawValue: 1), normalizedPeak: 0.9, peakToSidelobeRatio: 2, confidence: 0.8, primaryPeak: peak, sequence: sequence)
    let diagnostics = AcousticPathDiagnosticsAnalyzer().analyze(reference: reference, recording: recording, correlation: correlation)
    #expect(diagnostics.issues.contains { $0.code == .clippingDetected })
    #expect(diagnostics.issues.contains { $0.code == .polarityInversion })
    #expect(diagnostics.evidenceSummary.contains("Possible"))
    let quiet = try AudioSampleBuffer(samples: [0.001, 0.001, 0, 0], format: format)
    let quietDiagnostics = AcousticPathDiagnosticsAnalyzer().analyze(reference: reference, recording: quiet, correlation: correlation)
    #expect(quietDiagnostics.issues.contains { $0.code == .lowInputLevel })
}

@Test func acousticDiagnosticsFindsChannelImbalanceAndEchoCandidate() throws {
    let format = AudioFormatDescriptor(sampleRate: .hz48000, channelCount: 2, bitDepth: 32, isInterleaved: false)
    let reference = try AudioSampleBuffer(samples: [1, 0, 0, 0, 1, 0, 0, 0], format: format)
    let recording = try AudioSampleBuffer(samples: [0, 1, 0, 0, 0.001, 0, 0, 0], format: format)
    let primary = CorrelationPeak(lag: SampleCount(rawValue: 1), value: 1, overlapCount: SampleCount(rawValue: 4))
    var sequenceValues = [Float](repeating: 0, count: 30)
    sequenceValues[1] = 1
    sequenceValues[12] = 0.5
    let sequence = CorrelationSequence(firstLag: 0, values: sequenceValues)
    let correlation = CorrelationResult(peakOffset: SampleCount(rawValue: 1), normalizedPeak: 1, peakToSidelobeRatio: 2, confidence: 1, primaryPeak: primary, sequence: sequence)
    let diagnostics = AcousticPathDiagnosticsAnalyzer().analyze(reference: reference, recording: recording, correlation: correlation)
    #expect(diagnostics.issues.contains { $0.code == .multipleEchoes })
    #expect(diagnostics.issues.contains { $0.code == .channelImbalance })
    #expect(!diagnostics.earlyReflections.isEmpty)
}
