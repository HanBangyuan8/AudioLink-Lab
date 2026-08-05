import AudioLinkAdaptive
import AudioLinkCore
import AudioLinkDSP
import XCTest

final class AdaptiveMeasurementPlannerTests: XCTestCase {
    private let rate = SampleRate.hz48000
    func testCleanProbeIsDeterministic() throws {
        let planner = AdaptiveMeasurementPlanner()
        let env = MeasurementEnvironment(sampleRate: rate, inputRMS: 0.2, noiseFloorRMS: 0.001)
        let first = try planner.plan(objective: .balanced, environment: env)
        let second = try planner.plan(objective: .balanced, environment: env)
        XCTAssertEqual(first.decision.signalConfiguration, second.decision.signalConfiguration)
        XCTAssertTrue(first.diagnostics.constraintsRespected)
    }
    func testNoiseAndClippingHaveDifferentRules() throws {
        let planner = AdaptiveMeasurementPlanner()
        let noisy = try planner.plan(objective: .balanced, environment: MeasurementEnvironment(sampleRate: rate, inputRMS: 0.1, noiseFloorRMS: 0.05))
        XCTAssertEqual(noisy.decision.signalConfiguration.kind, .maximumLengthSequence)
        let clipped = try planner.plan(objective: .balanced, environment: MeasurementEnvironment(sampleRate: rate, clippingRatio: 0.02))
        XCTAssertLessThanOrEqual(clipped.decision.signalConfiguration.amplitude, 0.25)
    }
    func testLimitsAndLockedAmplitudeAreRespected() throws {
        let options = AdaptiveMeasurementOptions(limits: AdaptiveMeasurementLimits(maximumAmplitude: 0.2, maximumRetries: 1), locks: [.init(parameter: .amplitude, value: "0.15")])
        let plan = try AdaptiveMeasurementPlanner().plan(objective: .highPrecision, environment: MeasurementEnvironment(sampleRate: rate), options: options)
        XCTAssertEqual(plan.decision.signalConfiguration.amplitude, 0.15)
        XCTAssertEqual(plan.decision.retryStrategy.maximumAttempts, 1)
    }
    func testCancelledProbeIsRepresentableWithoutPlannerSideEffects() throws {
        let probe = ProbeMeasurement(duration: .fiftyMilliseconds, inputRMS: 0.01, noiseFloorRMS: 0.02)
        let plan = try AdaptiveMeasurementPlanner().plan(objective: .quick, environment: MeasurementEnvironment(sampleRate: rate), probe: probe)
        XCTAssertFalse(plan.decision.reasons.isEmpty)
        XCTAssertTrue(plan.decision.unknownInputs.isEmpty)
    }
    func testRetryControllerIsFiniteAndStopsOnNoImprovement() {
        let controller = RetryController(strategy: RetryStrategy(maximumAttempts: 2, adjustments: [.extendDuration]))
        XCTAssertNotNil(controller.nextAttempt(after: 0, previousConfidence: 0.4, currentConfidence: 0.5))
        XCTAssertNil(controller.nextAttempt(after: 1, previousConfidence: 0.5, currentConfidence: 0.5))
        XCTAssertNil(controller.nextAttempt(after: 2, previousConfidence: 0.5, currentConfidence: 0.9))
    }

    func testPlannerExposesDeterministicMultiObjectiveScore() throws {
        let planner = AdaptiveMeasurementPlanner()
        let environment = MeasurementEnvironment(sampleRate: rate, inputRMS: 0.2, noiseFloorRMS: 0.002)
        let first = try planner.plan(objective: .balanced, environment: environment)
        let second = try planner.plan(objective: .balanced, environment: environment)
        XCTAssertGreaterThanOrEqual(first.diagnostics.score.total, 0)
        XCTAssertLessThanOrEqual(first.diagnostics.score.total, 1)
        XCTAssertEqual(first.diagnostics.score, second.diagnostics.score)
    }
}
