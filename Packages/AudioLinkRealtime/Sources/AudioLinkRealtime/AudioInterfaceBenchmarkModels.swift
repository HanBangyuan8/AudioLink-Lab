import AudioLinkCore
import Foundation

public struct BenchmarkConfiguration: Codable, Equatable, Hashable, Sendable {
    public let inputDeviceID: String
    public let outputDeviceID: String
    public let inputChannel: Int
    public let outputChannel: Int
    public let sampleRate: SampleRate
    public let bufferFrameCount: Int

    public init(inputDeviceID: String, outputDeviceID: String, inputChannel: Int = 0, outputChannel: Int = 0, sampleRate: SampleRate, bufferFrameCount: Int) {
        self.inputDeviceID = inputDeviceID; self.outputDeviceID = outputDeviceID; self.inputChannel = inputChannel; self.outputChannel = outputChannel; self.sampleRate = sampleRate; self.bufferFrameCount = bufferFrameCount
    }
}

public struct BenchmarkPlan: Codable, Equatable, Sendable {
    public let runCount: Int
    public let warmUpCount: Int
    public let interval: DurationSeconds
    public let stopOnFailure: Bool
    public let maximumFailureCount: Int
    public let applyCalibration: Bool
    public let restoreOriginalDeviceConfiguration: Bool

    public init(runCount: Int = 5, warmUpCount: Int = 1, interval: DurationSeconds = .zero, stopOnFailure: Bool = false, maximumFailureCount: Int = 3, applyCalibration: Bool = false, restoreOriginalDeviceConfiguration: Bool = true) {
        self.runCount = max(1, runCount); self.warmUpCount = max(0, warmUpCount); self.interval = interval; self.stopOnFailure = stopOnFailure; self.maximumFailureCount = max(1, maximumFailureCount); self.applyCalibration = applyCalibration; self.restoreOriginalDeviceConfiguration = restoreOriginalDeviceConfiguration
    }
}

public struct BenchmarkMatrix: Codable, Equatable, Sendable {
    public let combinations: [BenchmarkConfiguration]
    public init(combinations: [BenchmarkConfiguration]) { self.combinations = combinations }
}

public enum BenchmarkMatrixBuilder {
    public static func make(inputDeviceID: String, outputDeviceID: String, inputChannel: Int = 0, outputChannel: Int = 0, sampleRates: [SampleRate], bufferSizes: [Int], advertisedRates: [SampleRate], advertisedBufferRange: AudioBufferRange?) -> BenchmarkMatrix {
        let rates = sampleRates.filter { advertisedRates.contains($0) }
        let buffers = bufferSizes.filter { size in advertisedBufferRange?.contains(size) ?? false }
        return BenchmarkMatrix(combinations: rates.flatMap { rate in buffers.map { BenchmarkConfiguration(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID, inputChannel: inputChannel, outputChannel: outputChannel, sampleRate: rate, bufferFrameCount: $0) } })
    }
}

public struct ReportedLatencyMetrics: Codable, Equatable, Sendable {
    public let inputFrames: Int?
    public let outputFrames: Int?
    public let safetyOffsetFrames: Int?
    public let streamFrames: Int?
    public init(inputFrames: Int? = nil, outputFrames: Int? = nil, safetyOffsetFrames: Int? = nil, streamFrames: Int? = nil) { self.inputFrames = inputFrames; self.outputFrames = outputFrames; self.safetyOffsetFrames = safetyOffsetFrames; self.streamFrames = streamFrames }
}

public struct TheoreticalLatency: Codable, Equatable, Sendable {
    public let bufferFrames: Int
    public let sampleRate: SampleRate
    public let inputFrames: Int
    public let outputFrames: Int
    public let safetyOffsetFrames: Int
    public let streamFrames: Int

    public init(bufferFrames: Int, sampleRate: SampleRate, reported: ReportedLatencyMetrics) {
        self.bufferFrames = bufferFrames; self.sampleRate = sampleRate
        self.inputFrames = reported.inputFrames ?? 0; self.outputFrames = reported.outputFrames ?? 0
        self.safetyOffsetFrames = reported.safetyOffsetFrames ?? 0; self.streamFrames = reported.streamFrames ?? 0
    }

    public var frames: Int { (2 * bufferFrames) + inputFrames + outputFrames + safetyOffsetFrames + streamFrames }
    public var seconds: Double { Double(frames) / sampleRate.hertz }
}

public struct MeasuredLatency: Codable, Equatable, Sendable {
    public let rawFrames: Double
    public let calibratedFrames: Double?
    public let sampleRate: SampleRate
    public init(rawFrames: Double, calibratedFrames: Double? = nil, sampleRate: SampleRate) { self.rawFrames = rawFrames; self.calibratedFrames = calibratedFrames; self.sampleRate = sampleRate }
    public var milliseconds: Double { rawFrames / sampleRate.hertz * 1_000 }
}

public struct BenchmarkRunMetrics: Codable, Equatable, Sendable {
    public let measured: MeasuredLatency
    public let reported: ReportedLatencyMetrics
    public let theoretical: TheoreticalLatency
    public let unexplainedFrames: Double
    public let jitterFrames: Double?
    public let underflowCount: Int
    public let overflowCount: Int
    public let discontinuityCount: Int
    public let cpuLoad: Double?
    public let processingDeadlineMisses: Int
    public let driftPPM: Double?
    public let channelConsistent: Bool?
    public let polarityInverted: Bool?
    public let noiseFloor: Double?
    public let clipping: Bool?

    public init(measured: MeasuredLatency, reported: ReportedLatencyMetrics, theoretical: TheoreticalLatency, jitterFrames: Double? = nil, underflowCount: Int = 0, overflowCount: Int = 0, discontinuityCount: Int = 0, cpuLoad: Double? = nil, processingDeadlineMisses: Int = 0, driftPPM: Double? = nil, channelConsistent: Bool? = nil, polarityInverted: Bool? = nil, noiseFloor: Double? = nil, clipping: Bool? = nil) {
        self.measured = measured; self.reported = reported; self.theoretical = theoretical; self.unexplainedFrames = measured.rawFrames - Double(theoretical.frames); self.jitterFrames = jitterFrames; self.underflowCount = underflowCount; self.overflowCount = overflowCount; self.discontinuityCount = discontinuityCount; self.cpuLoad = cpuLoad; self.processingDeadlineMisses = processingDeadlineMisses; self.driftPPM = driftPPM; self.channelConsistent = channelConsistent; self.polarityInverted = polarityInverted; self.noiseFloor = noiseFloor; self.clipping = clipping
    }
}

public struct BenchmarkFailure: Codable, Equatable, Sendable, Identifiable {
    public enum Code: String, Codable, Sendable { case unsupportedCombination, deviceDisconnected, configurationFailed, playbackFailed, recordingFailed, analysisFailed, cancelled, restorationFailed, timeout, unknown }
    public let id: UUID
    public let combination: BenchmarkConfiguration
    public let code: Code
    public let message: String
    public let occurredAt: Date
    public init(id: UUID = UUID(), combination: BenchmarkConfiguration, code: Code, message: String, occurredAt: Date = Date()) { self.id = id; self.combination = combination; self.code = code; self.message = message; self.occurredAt = occurredAt }
}

public struct BenchmarkResult: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let combination: BenchmarkConfiguration
    public let runIndex: Int
    public let isWarmUp: Bool
    public let metrics: BenchmarkRunMetrics?
    public let failure: BenchmarkFailure?
    public let startedAt: Date
    public let completedAt: Date
    public init(id: UUID = UUID(), combination: BenchmarkConfiguration, runIndex: Int, isWarmUp: Bool, metrics: BenchmarkRunMetrics? = nil, failure: BenchmarkFailure? = nil, startedAt: Date = Date(), completedAt: Date = Date()) { self.id = id; self.combination = combination; self.runIndex = runIndex; self.isWarmUp = isWarmUp; self.metrics = metrics; self.failure = failure; self.startedAt = startedAt; self.completedAt = completedAt }
}

public struct DeviceBenchmarkSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let combination: BenchmarkConfiguration
    public let results: [BenchmarkResult]
    public let recommendationScore: Double
    public let recommendationReason: String
    public init(id: UUID = UUID(), combination: BenchmarkConfiguration, results: [BenchmarkResult], recommendationScore: Double, recommendationReason: String) { self.id = id; self.combination = combination; self.results = results; self.recommendationScore = recommendationScore; self.recommendationReason = recommendationReason }
    public var successfulMetrics: [BenchmarkRunMetrics] { results.compactMap(\.metrics) }
    public var failureRate: Double { results.isEmpty ? 1 : Double(results.filter { $0.failure != nil }.count) / Double(results.count) }
}

public enum BenchmarkMath {
    public static func unexplainedFrames(measured: Double, theoretical: TheoreticalLatency) -> Double { measured - Double(theoretical.frames) }
    public static func score(summary: DeviceBenchmarkSummary) -> Double {
        let metrics = summary.successfulMetrics
        guard !metrics.isEmpty else { return 0 }
        let jitter = metrics.compactMap(\.jitterFrames).reduce(0, +) / Double(max(1, metrics.compactMap(\.jitterFrames).count))
        let misses = metrics.reduce(0) { $0 + $1.processingDeadlineMisses }
        return max(0, 1 - min(1, summary.failureRate * 0.6 + min(1, jitter / 8_000) * 0.25 + min(1, Double(misses) / 10) * 0.15))
    }
}

public struct DeviceConfigurationSnapshot: Codable, Equatable, Sendable {
    public let sampleRate: SampleRate
    public let bufferFrameCount: Int
    public init(sampleRate: SampleRate, bufferFrameCount: Int) { self.sampleRate = sampleRate; self.bufferFrameCount = bufferFrameCount }
}

public struct ConfigurationRestorationResult: Codable, Equatable, Sendable {
    public let restored: Bool
    public let warning: String?
    public init(restored: Bool, warning: String? = nil) { self.restored = restored; self.warning = warning }
}

public protocol AudioDeviceConfigurationTransaction: Sendable {
    func capture() async throws -> DeviceConfigurationSnapshot
    func apply(_ target: BenchmarkConfiguration) async throws
    func waitForStability() async throws
    func confirm() async throws -> DeviceConfigurationSnapshot
    func restore(_ snapshot: DeviceConfigurationSnapshot) async throws -> ConfigurationRestorationResult
}

public enum AudioDeviceConfigurationTransactionError: Error, Equatable, Sendable { case applyFailed(String); case confirmationFailed(String); case restorationFailed(String) }

public actor BenchmarkRunner {
    public typealias Execute = @Sendable (BenchmarkConfiguration, Int, Bool) async throws -> BenchmarkRunMetrics
    private let transaction: any AudioDeviceConfigurationTransaction
    private let execute: Execute

    public init(transaction: any AudioDeviceConfigurationTransaction, execute: @escaping Execute) { self.transaction = transaction; self.execute = execute }

    public func run(plan: BenchmarkPlan, matrix: BenchmarkMatrix) async -> [BenchmarkResult] {
        guard !matrix.combinations.isEmpty else { return [] }
        var output: [BenchmarkResult] = []
        for combination in matrix.combinations {
            if Task.isCancelled { break }
            let started = Date()
            let original: DeviceConfigurationSnapshot
            do { original = try await transaction.capture() }
            catch {
                output.append(BenchmarkResult(combination: combination, runIndex: 0, isWarmUp: false, failure: BenchmarkFailure(combination: combination, code: .configurationFailed, message: error.localizedDescription), startedAt: started))
                continue
            }
            do { try await transaction.apply(combination); try await transaction.waitForStability(); _ = try await transaction.confirm() }
            catch {
                output.append(BenchmarkResult(combination: combination, runIndex: 0, isWarmUp: false, failure: BenchmarkFailure(combination: combination, code: .configurationFailed, message: error.localizedDescription), startedAt: started))
                if plan.restoreOriginalDeviceConfiguration { await appendRestorationFailureIfNeeded(for: combination, original: original, to: &output) }
                continue
            }
            var failures = 0
            let total = plan.runCount + plan.warmUpCount
            for index in 0..<total {
                if Task.isCancelled { output.append(BenchmarkResult(combination: combination, runIndex: index, isWarmUp: index < plan.warmUpCount, failure: BenchmarkFailure(combination: combination, code: .cancelled, message: "Benchmark cancelled."), startedAt: Date())); break }
                let runStart = Date()
                do {
                    let metrics = try await execute(combination, index, index < plan.warmUpCount)
                    output.append(BenchmarkResult(combination: combination, runIndex: index, isWarmUp: index < plan.warmUpCount, metrics: metrics, startedAt: runStart))
                } catch {
                    failures += 1
                    output.append(BenchmarkResult(combination: combination, runIndex: index, isWarmUp: index < plan.warmUpCount, failure: BenchmarkFailure(combination: combination, code: .analysisFailed, message: error.localizedDescription), startedAt: runStart))
                    if plan.stopOnFailure || failures >= plan.maximumFailureCount { break }
                }
                if plan.interval.value > 0 { try? await Task.sleep(for: .milliseconds(Int(plan.interval.value * 1_000))) }
            }
            if plan.restoreOriginalDeviceConfiguration { await appendRestorationFailureIfNeeded(for: combination, original: original, to: &output) }
        }
        return output
    }

    private func appendRestorationFailureIfNeeded(for combination: BenchmarkConfiguration, original: DeviceConfigurationSnapshot, to output: inout [BenchmarkResult]) async {
        do {
            let result = try await transaction.restore(original)
            if !result.restored {
                output.append(BenchmarkResult(combination: combination, runIndex: -1, isWarmUp: false, failure: BenchmarkFailure(combination: combination, code: .restorationFailed, message: result.warning ?? "The original device configuration could not be confirmed.")))
            }
        } catch {
            output.append(BenchmarkResult(combination: combination, runIndex: -1, isWarmUp: false, failure: BenchmarkFailure(combination: combination, code: .restorationFailed, message: error.localizedDescription)))
        }
    }
}
