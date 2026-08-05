import XCTest
@testable import AudioLinkPlugin

final class AudioUnitProfilerTests: XCTestCase {
    func testFixedDelayIsMeasuredSeparatelyFromReportedValue() async throws {
        let identity = AudioUnitComponentIdentity(type: 1, subtype: 2, manufacturer: 3, version: "1")
        let descriptor = AudioUnitDescriptor(identity: identity, name: "Mock", reportedLatencyFrames: 4)
        let profiler = AudioUnitProfiler(runner: MockAudioUnitPlugin(kind: .fixedDelay, delayFrames: 12))
        let result = try await profiler.profile(plugin: descriptor, configuration: PluginTestConfiguration(sampleRate: .hz48000, durationSeconds: 0.01))
        XCTAssertEqual(result.latency.measuredFrames, 12)
        XCTAssertEqual(result.latency.reportedFrames, 4)
        XCTAssertEqual(result.latency.differenceFrames, 8)
    }

    func testInvalidOutputIsRejected() async throws {
        let identity = AudioUnitComponentIdentity(type: 1, subtype: 2, manufacturer: 3, version: "1")
        let descriptor = AudioUnitDescriptor(identity: identity, name: "Mock")
        let profiler = AudioUnitProfiler(runner: MockAudioUnitPlugin(kind: .nanOutput))
        do { _ = try await profiler.profile(plugin: descriptor, configuration: PluginTestConfiguration(sampleRate: .hz48000, durationSeconds: 0.01)); XCTFail("expected invalid output") }
        catch let error as AudioUnitProfilerError { XCTAssertEqual(error, .invalidOutput("NaN or infinity")) }
    }

    func testAnalysisMathSeparatesGainAndTail() throws {
        let sampleRate = 48_000.0
        let input = (0..<4_800).map { Float(sin(2 * .pi * 1_000 * Double($0) / sampleRate)) }
        let output = input.map { $0 * 0.5 } + Array(repeating: Float.zero, count: 48)
        let response = PluginAnalysisMath.frequencyResponse(input: input, output: output, sampleRate: sampleRate, frequencies: [1_000])
        XCTAssertEqual(response.magnitudeDB[0], -6.02, accuracy: 0.2)
        guard let tail = PluginAnalysisMath.tailTime(samples: output, sampleRate: sampleRate) else { return XCTFail("expected tail") }
        XCTAssertEqual(tail, 0.0999, accuracy: 0.001)
    }

    func testPhaseResponseUnwrapsBeforeGroupDelay() throws {
        let sampleRate = 48_000.0
        let delay = 20
        let input = [Float](arrayLiteral: 1) + [Float](repeating: 0, count: 4_799)
        let output = [Float](repeating: 0, count: delay) + [Float](arrayLiteral: 1) + [Float](repeating: 0, count: 4_799 - delay)
        // Phase unwrapping is only identifiable when adjacent frequency
        // samples are dense enough that the phase step is below π.
        let frequencies = stride(from: 100.0, through: 18_000.0, by: 500.0).map { $0 }
        let response = PluginAnalysisMath.phaseResponse(input: input, output: output, sampleRate: sampleRate, frequencies: frequencies)
        for value in response.groupDelaySeconds.dropFirst() {
            XCTAssertEqual(value, Double(delay) / sampleRate, accuracy: 1e-8)
        }
    }
}
