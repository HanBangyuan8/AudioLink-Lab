import AudioLinkCore
import AudioLinkDSP
import XCTest
@testable import AudioLinkRealtime

final class RepeatedMeasurementControllerTests: XCTestCase {
    func testWarmupIsRetainedButDiscardedFromAggregate() async throws {
        let fixture = try ControllerFixture(delays: [10, 11, 12])
        let report = try await fixture.controller.execute(
            plan: try fixture.plan(runCount: 2, warmups: 1),
            baseConfiguration: fixture.configuration,
            stateHandler: nil
        )

        XCTAssertEqual(report.outcomes.count, 3)
        XCTAssertTrue(report.outcomes[0].isWarmUp)
        XCTAssertTrue(report.outcomes[0].isDiscardedWarmUp)
        XCTAssertEqual(report.statisticsIncludingOutliers.outcomeCount, 2)
        XCTAssertEqual(report.statisticsIncludingOutliers.successCount, 2)
        XCTAssertEqual(report.statisticsIncludingOutliers.meanMilliseconds ?? 0, 11.5, accuracy: 0.000_1)
        let savedCount = await fixture.saver.count
        XCTAssertEqual(savedCount, 3)
    }

    func testRepeatedFailuresStopAtConfiguredConsecutiveLimit() async throws {
        let failure = RealtimeMeasurementFailure(
            code: .recordingFailed,
            userMessage: "mock failure",
            recoverySuggestion: "retry"
        )
        let fixture = try ControllerFixture(failures: [failure, failure, failure])
        do {
            _ = try await fixture.controller.execute(
                plan: try fixture.plan(runCount: 5, warmups: 0, maximumFailures: 2),
                baseConfiguration: fixture.configuration,
                stateHandler: nil
            )
            XCTFail("Expected repeated failure stop")
        } catch let error as RepeatedMeasurementError {
            XCTAssertEqual(error, .repeatedFailures(count: 2))
        }
        let callCount = await fixture.runner.callCount
        let savedCount = await fixture.saver.count
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(savedCount, 2)
    }

    func testRouteChangeStopsBeforeMixingSecondRun() async throws {
        let fixture = try ControllerFixture(delays: [10, 11], failValidationAt: 3)
        do {
            _ = try await fixture.controller.execute(
                plan: try fixture.plan(runCount: 2, warmups: 0),
                baseConfiguration: fixture.configuration,
                stateHandler: nil
            )
            XCTFail("Expected route change")
        } catch let error as RepeatedMeasurementError {
            guard case .routeChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let callCount = await fixture.runner.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testCancelStopsActiveRun() async throws {
        let fixture = try ControllerFixture(delays: [10], blockFirstRun: true)
        let task = Task {
            try await fixture.controller.execute(
                plan: try fixture.plan(runCount: 1, warmups: 0),
                baseConfiguration: fixture.configuration,
                stateHandler: nil
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        await fixture.controller.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as RepeatedMeasurementError {
            XCTAssertEqual(error, .cancelled)
        }
        let stopCount = await fixture.runner.stopCount
        XCTAssertGreaterThanOrEqual(stopCount, 1)
    }

    func testPauseStopsCurrentRunThenResumeRevalidatesAndRetriesSameStep() async throws {
        let fixture = try ControllerFixture(delays: [10], blockFirstRun: true)
        let states = SnapshotRecorder()
        let task = Task {
            try await fixture.controller.execute(
                plan: try fixture.plan(runCount: 1, warmups: 0),
                baseConfiguration: fixture.configuration,
                stateHandler: { states.append($0) }
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        await fixture.controller.pause()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(states.values.contains { if case .paused = $0.state { true } else { false } })
        try await fixture.controller.resume()
        let report = try await task.value
        XCTAssertEqual(report.outcomes.count, 1)
        let callCount = await fixture.runner.callCount
        let validationCount = await fixture.devices.validationCount
        XCTAssertEqual(callCount, 2)
        XCTAssertGreaterThanOrEqual(validationCount, 3)
    }

    func testDeviceChangeDuringPauseMakesResumeAbortPlan() async throws {
        let fixture = try ControllerFixture(delays: [10], failValidationAt: 3, blockFirstRun: true)
        let task = Task {
            try await fixture.controller.execute(
                plan: try fixture.plan(runCount: 1, warmups: 0),
                baseConfiguration: fixture.configuration,
                stateHandler: nil
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        await fixture.controller.pause()
        do {
            try await fixture.controller.resume()
            XCTFail("Expected route revalidation failure")
        } catch let error as RepeatedMeasurementError {
            guard case .routeChanged = error else {
                return XCTFail("Unexpected resume error: \(error)")
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected plan to abort")
        } catch let error as RepeatedMeasurementError {
            guard case .routeChanged = error else {
                return XCTFail("Unexpected plan error: \(error)")
            }
        }
    }
}

private struct ControllerFixture {
    let runner: PlanMockRunner
    let devices: PlanMockDeviceService
    let saver: PlanMockProgressSaver
    let controller: RepeatedMeasurementController
    let configuration: RealtimeMeasurementConfiguration

    init(
        delays: [Double] = [],
        failures: [RealtimeMeasurementFailure] = [],
        failValidationAt: Int? = nil,
        blockFirstRun: Bool = false
    ) throws {
        let input = Self.device(id: "input", name: "Mock Input", input: 2, output: 0)
        let output = Self.device(id: "output", name: "Mock Output", input: 0, output: 2)
        runner = PlanMockRunner(delays: delays, failures: failures, blockFirstRun: blockFirstRun)
        devices = PlanMockDeviceService(devices: [input, output], failValidationAt: failValidationAt)
        saver = PlanMockProgressSaver()
        controller = RepeatedMeasurementController(
            runner: runner,
            deviceService: devices,
            scheduler: ImmediatePlanScheduler(),
            progressSaver: saver
        )
        configuration = RealtimeMeasurementConfiguration(
            route: AudioRouteConfiguration(
                inputDevice: input,
                outputDevice: output,
                sampleRate: .hz48000
            ),
            signal: TestSignalConfiguration(
                kind: .impulse,
                sampleRate: .hz48000,
                duration: try DurationSeconds(0.01),
                amplitude: 0.2,
                deterministicSeed: 100
            ),
            preRoll: .zero,
            postRoll: .zero,
            correlation: CorrelationConfiguration(
                searchRange: SampleLagRange(minimum: 0, maximum: 48_000)
            )
        )
    }

    func plan(
        runCount: Int,
        warmups: Int,
        maximumFailures: Int = 3
    ) throws -> MeasurementPlan {
        MeasurementPlan(
            runCount: runCount,
            intervalBetweenRuns: .zero,
            warmUpRuns: warmups,
            discardWarmUp: true,
            stopOnRepeatedFailure: true,
            maximumFailureCount: maximumFailures,
            preRoll: .zero,
            postRoll: .zero,
            signalKind: .impulse,
            randomSeedPolicy: .incrementing
        )
    }

    private static func device(
        id: String,
        name: String,
        input: Int,
        output: Int
    ) -> AudioDeviceDescription {
        AudioDeviceDescription(
            descriptor: DeviceDescriptor(
                id: id,
                name: name,
                transport: .virtual,
                supportsInput: input > 0,
                supportsOutput: output > 0
            ),
            nominalSampleRate: .hz48000,
            inputChannelCount: input,
            outputChannelCount: output,
            isDefaultInput: input > 0,
            isDefaultOutput: output > 0
        )
    }
}

private actor PlanMockRunner: RealtimeMeasurementRunning {
    private var delays: [Double]
    private var failures: [RealtimeMeasurementFailure]
    private let blockFirstRun: Bool
    private var shouldStop = false
    private(set) var callCount = 0
    private(set) var stopCount = 0

    init(delays: [Double], failures: [RealtimeMeasurementFailure], blockFirstRun: Bool) {
        self.delays = delays
        self.failures = failures
        self.blockFirstRun = blockFirstRun
    }

    func measure(
        configuration: RealtimeMeasurementConfiguration,
        stateHandler: (@Sendable (RealtimeMeasurementState) -> Void)?
    ) async throws -> RealtimeMeasurementResult {
        callCount += 1
        if blockFirstRun, callCount == 1 {
            while !shouldStop { try await Task.sleep(for: .milliseconds(2)) }
            shouldStop = false
            throw RealtimeMeasurementFailure(
                code: .cancelled,
                userMessage: "stopped",
                recoverySuggestion: "resume"
            )
        }
        if !failures.isEmpty { throw failures.removeFirst() }
        guard !delays.isEmpty else {
            throw RealtimeMeasurementFailure(
                code: .analysisFailed,
                userMessage: "No mock result",
                recoverySuggestion: "Add a fixture result"
            )
        }
        return try Self.result(delayMilliseconds: delays.removeFirst(), configuration: configuration)
    }

    func preview(configuration: RealtimeMeasurementConfiguration) async throws {}

    func stop() async {
        stopCount += 1
        shouldStop = true
    }

    private static func result(
        delayMilliseconds: Double,
        configuration: RealtimeMeasurementConfiguration
    ) throws -> RealtimeMeasurementResult {
        let generated = try TestSignalGenerator().generate(configuration: configuration.signal)
        let original = AudioFileFormatDescription(
            container: .wav,
            encoding: .ieeeFloat,
            sampleRate: configuration.route.sampleRate,
            channelCount: 1,
            bitDepth: 32,
            isInterleaved: true,
            isBigEndian: false,
            formatIdentifier: "mock"
        )
        let metrics = AudioAnalysisMetrics(
            peakMagnitude: generated.audio.peakMagnitude,
            rootMeanSquare: generated.audio.rootMeanSquare,
            clippingSampleCount: 0,
            dcOffset: 0,
            channelDCOffsets: [0]
        )
        let reference = ImportedAudioFile(
            fileURL: URL(fileURLWithPath: "/mock/reference.wav"),
            fileName: "reference.wav",
            originalFormat: original,
            audio: generated.audio,
            analysis: metrics
        )
        let recording = ImportedAudioFile(
            fileURL: URL(fileURLWithPath: "/mock/recording.wav"),
            fileName: "recording.wav",
            originalFormat: original,
            audio: generated.audio,
            analysis: metrics
        )
        let fractionalSamples = delayMilliseconds / 1_000 * configuration.route.sampleRate.hertz
        let delay = DelayEstimate(
            sampleOffset: SampleCount(rawValue: Int64(fractionalSamples.rounded())),
            sampleRate: configuration.route.sampleRate,
            confidence: 0.95,
            fractionalSampleOffset: fractionalSamples,
            peakAmplitude: 0.9,
            peakToSidelobeRatio: 10,
            isReliable: true
        )
        let quality = MeasurementQuality(
            level: .good,
            confidence: ConfidenceScore(value: 0.95, components: []),
            summary: "Stable mock run",
            metrics: [],
            issues: [],
            peakAmbiguity: PeakAmbiguity(
                candidates: [],
                primaryToSecondaryRatio: nil,
                hasSimilarPeaks: false,
                peakSpacings: [],
                periodicInterval: nil,
                explanation: "No ambiguity"
            ),
            signal: SignalQualityAnalysis(
                referenceRMS: 0.1,
                observedRMS: 0.1,
                signalToNoiseDecibels: 40,
                clippingRatio: 0,
                dcOffsetMagnitude: 0,
                referenceCoverageRatio: 1,
                isPolarityInverted: false,
                appearsTruncated: false,
                channelsConsistent: true,
                channelDelaySpreadSamples: 0,
                channelPeakSpread: 0
            ),
            delayDiagnostics: DelayEstimateDiagnostics(
                selectedDelay: delay,
                candidatePeaks: [],
                peakWidthSamples: 1,
                localPeakSharpness: 1,
                searchBoundaryDistance: SampleCount(rawValue: 100),
                channelResults: []
            ),
            shouldRemeasure: false
        )
        return RealtimeMeasurementResult(
            startedAt: Date(),
            completedAt: Date(),
            configuration: configuration,
            generatedSignal: generated,
            preparedReference: reference,
            preparedRecording: recording,
            assessment: QualityAssessedMeasurement(delay: delay, correlation: nil, quality: quality),
            diagnostics: AudioEngineDiagnostics(
                bufferFrameCount: configuration.route.bufferFrameCount,
                nominalSampleRate: configuration.route.sampleRate,
                recordingBeganBeforePlayback: true
            )
        )
    }
}

private actor PlanMockDeviceService: AudioDeviceService {
    private let available: [AudioDeviceDescription]
    private let failValidationAt: Int?
    private(set) var validationCount = 0

    init(devices: [AudioDeviceDescription], failValidationAt: Int?) {
        available = devices
        self.failValidationAt = failValidationAt
    }

    func devices() async throws -> [AudioDeviceDescription] { available }
    func defaultInputDevice() async throws -> AudioDeviceDescription? { available.first { $0.inputChannelCount > 0 } }
    func defaultOutputDevice() async throws -> AudioDeviceDescription? { available.first { $0.outputChannelCount > 0 } }
    func validate(route: AudioRouteConfiguration) async throws {
        validationCount += 1
        if validationCount == failValidationAt {
            throw RealtimeMeasurementFailure(
                code: .deviceDisconnected,
                userMessage: "route changed",
                recoverySuggestion: "stop"
            )
        }
    }
    nonisolated func events() -> AsyncStream<AudioDeviceEvent> { AsyncStream { $0.finish() } }
}

private struct ImmediatePlanScheduler: RunScheduling {
    func wait(for duration: DurationSeconds) async throws {
        if duration.value > 0 { try await Task.sleep(for: .milliseconds(2)) }
    }
}

private actor PlanMockProgressSaver: RepeatedMeasurementProgressSaving {
    private(set) var count = 0
    func record(
        outcome: RunOutcome,
        plan: MeasurementPlan,
        baseConfiguration: RealtimeMeasurementConfiguration,
        statistics: RepeatedMeasurementStatistics?
    ) async throws { count += 1 }
}

private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RepeatedMeasurementSnapshot] = []
    var values: [RepeatedMeasurementSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func append(_ snapshot: RepeatedMeasurementSnapshot) {
        lock.lock(); storage.append(snapshot); lock.unlock()
    }
}
