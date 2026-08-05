import AudioLinkCore
import XCTest
@testable import AudioLinkRealtime

final class AudioInterfaceBenchmarkTests: XCTestCase {
    func testMatrixFiltersUnsupportedRatesAndBuffers() throws {
        let matrix = BenchmarkMatrixBuilder.make(inputDeviceID: "in", outputDeviceID: "out", sampleRates: [.hz44100, .hz48000, .hz96000], bufferSizes: [32, 64, 256], advertisedRates: [.hz48000], advertisedBufferRange: AudioBufferRange(minimum: 32, maximum: 128))
        XCTAssertEqual(matrix.combinations.map(\.sampleRate), [.hz48000, .hz48000])
        XCTAssertEqual(matrix.combinations.map(\.bufferFrameCount), [32, 64])
    }

    func testTheoreticalAndUnexplainedLatencyRemainSeparate() throws {
        let rate = try SampleRate(hertz: 48_000)
        let reported = ReportedLatencyMetrics(inputFrames: 10, outputFrames: 12, safetyOffsetFrames: 4, streamFrames: 2)
        let theoretical = TheoreticalLatency(bufferFrames: 64, sampleRate: rate, reported: reported)
        let measured = MeasuredLatency(rawFrames: 160, sampleRate: rate)
        let metrics = BenchmarkRunMetrics(measured: measured, reported: reported, theoretical: theoretical)
        XCTAssertEqual(theoretical.frames, 156)
        XCTAssertEqual(metrics.unexplainedFrames, 4)
    }

    func testRunnerKeepsFailuresAndUsesRestorationPath() async throws {
        let transaction = MockTransaction()
        let runner = BenchmarkRunner(transaction: transaction) { _, index, _ in
            if index == 1 { throw TestFailure.failed }
            let rate = try SampleRate(hertz: 48_000)
            let reported = ReportedLatencyMetrics()
            let theoretical = TheoreticalLatency(bufferFrames: 64, sampleRate: rate, reported: reported)
            return BenchmarkRunMetrics(measured: MeasuredLatency(rawFrames: 128, sampleRate: rate), reported: reported, theoretical: theoretical)
        }
        let matrix = BenchmarkMatrix(combinations: [BenchmarkConfiguration(inputDeviceID: "in", outputDeviceID: "out", sampleRate: .hz48000, bufferFrameCount: 64)])
        let results = await runner.run(plan: BenchmarkPlan(runCount: 2, warmUpCount: 0), matrix: matrix)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.filter { $0.failure != nil }.count, 1)
        let restoreCount = await transaction.restores
        XCTAssertEqual(restoreCount, 1)
    }
}

private enum TestFailure: Error { case failed }

private actor MockTransaction: AudioDeviceConfigurationTransaction {
    var restores = 0
    func capture() async throws -> DeviceConfigurationSnapshot { DeviceConfigurationSnapshot(sampleRate: .hz44100, bufferFrameCount: 128) }
    func apply(_ target: BenchmarkConfiguration) async throws {}
    func waitForStability() async throws {}
    func confirm() async throws -> DeviceConfigurationSnapshot { DeviceConfigurationSnapshot(sampleRate: .hz48000, bufferFrameCount: 64) }
    func restore(_ snapshot: DeviceConfigurationSnapshot) async throws -> ConfigurationRestorationResult { restores += 1; return ConfigurationRestorationResult(restored: true) }
}
