import AudioLinkCore
import AudioLinkDSP
import Foundation

/// Schedules short, isolated measurements. A route validation is performed
/// before every event so sleep/route interruptions never silently contaminate
/// a stability series.
public actor LongTermStabilityController: LongTermStabilityControlling {
    private let runner: any RealtimeMeasurementRunning
    private let deviceService: any AudioDeviceService
    private let scheduler: any RunScheduling
    private let driftEstimator: ClockDriftEstimator
    private var active = false
    private var pauseRequested = false
    private var cancelRequested = false
    private var frozenRoute: AudioRouteConfiguration?
    private var handler: LongTermStabilityStateHandler?
    private var latestSnapshot: LongTermStabilitySnapshot?

    public init(
        runner: any RealtimeMeasurementRunning,
        deviceService: any AudioDeviceService,
        scheduler: any RunScheduling = RunScheduler(),
        driftEstimator: ClockDriftEstimator = .init()
    ) {
        self.runner = runner
        self.deviceService = deviceService
        self.scheduler = scheduler
        self.driftEstimator = driftEstimator
    }

    public func execute(
        plan: LongTermStabilityPlan,
        baseConfiguration: RealtimeMeasurementConfiguration,
        stateHandler: LongTermStabilityStateHandler? = nil
    ) async throws -> LongTermStabilityReport {
        guard !active else { throw LongTermStabilityError.alreadyRunning }
        try plan.validate()
        active = true
        pauseRequested = false
        cancelRequested = false
        frozenRoute = baseConfiguration.route
        handler = stateHandler
        let startedAt = Date()
        var observations: [LongTermStabilityObservation] = []
        var failures: [RepeatedMeasurementRunFailure] = []
        var discontinuities: [Int] = []
        var routeChanged = false
        defer {
            active = false
            pauseRequested = false
            cancelRequested = false
            frozenRoute = nil
            handler = nil
        }

        do {
            publish(state: .preparing, plan: plan, observations: observations, failures: failures)
            try await validateRoute()
            for index in 0..<plan.scheduledEventCount {
                try await waitWhilePaused(plan: plan, observations: observations, failures: failures)
                try ensureNotCancelled()
                do {
                    try await validateRoute()
                } catch {
                    routeChanged = true
                    let message = "The audio route changed during the stability test; later events were not mixed into this series."
                    publish(state: .terminated(reason: message), plan: plan, observations: observations, failures: failures)
                    if plan.stopOnRouteChange {
                        throw LongTermStabilityError.routeChanged(message)
                    }
                    throw LongTermStabilityError.interrupted("The route changed and no replacement configuration was provided; the stability series was terminated.")
                }
                publish(state: .running(current: index + 1, total: plan.scheduledEventCount), plan: plan, observations: observations, failures: failures)
                let signal = TestSignalConfiguration(
                    kind: .shortChirp,
                    sampleRate: baseConfiguration.signal.sampleRate,
                    duration: plan.chirpDuration,
                    startFrequencyHertz: baseConfiguration.signal.startFrequencyHertz,
                    endFrequencyHertz: baseConfiguration.signal.endFrequencyHertz,
                    amplitude: baseConfiguration.signal.amplitude,
                    preRollSilence: baseConfiguration.signal.preRollSilence,
                    postRollSilence: baseConfiguration.signal.postRollSilence,
                    fadeIn: baseConfiguration.signal.fadeIn,
                    fadeOut: baseConfiguration.signal.fadeOut,
                    channelCount: baseConfiguration.signal.channelCount,
                    deterministicSeed: baseConfiguration.signal.deterministicSeed &+ UInt64(index),
                    sweepDirection: baseConfiguration.signal.sweepDirection,
                    polarity: baseConfiguration.signal.polarity,
                    maximumLengthSequenceOrder: baseConfiguration.signal.maximumLengthSequenceOrder
                )
                let configuration = RealtimeMeasurementConfiguration(
                    route: baseConfiguration.route,
                    signal: signal,
                    preRoll: plan.preRoll,
                    postRoll: plan.postRoll,
                    correlation: baseConfiguration.correlation,
                    preprocessing: baseConfiguration.preprocessing,
                    measurementGroupID: plan.id,
                    planRunSequence: index + 1
                )
                do {
                    let result = try await runner.measure(configuration: configuration, stateHandler: nil)
                    guard let delay = result.assessment.delay else {
                        throw LongTermStabilityError.interrupted("The event completed without a usable delay estimate.")
                    }
                    let delayMS = delay.fractionalMilliseconds
                    let previous = observations.last?.delayMilliseconds
                    let jump = previous.map { abs(delayMS - $0) }
                    if let jump, jump >= plan.discontinuityThresholdMilliseconds { discontinuities.append(index) }
                    observations.append(LongTermStabilityObservation(
                        id: result.id,
                        eventIndex: index,
                        occurredAt: result.completedAt,
                        delayMilliseconds: delayMS,
                        quality: result.assessment.quality.level,
                        discontinuityMilliseconds: jump,
                        route: baseConfiguration.route
                    ))
                } catch is CancellationError {
                    throw LongTermStabilityError.cancelled
                } catch let error as RealtimeMeasurementFailure {
                    failures.append(RepeatedMeasurementRunFailure(failure: error))
                } catch let error as LongTermStabilityError {
                    if case .cancelled = error { throw error }
                    failures.append(RepeatedMeasurementRunFailure(failure: RealtimeMeasurementFailure(
                        code: .analysisFailed,
                        userMessage: error.localizedDescription,
                        recoverySuggestion: "Review the event diagnostics and restart the stability test.",
                        technicalContext: nil
                    )))
                } catch {
                    failures.append(RepeatedMeasurementRunFailure(failure: RealtimeMeasurementFailure(
                        code: .analysisFailed,
                        userMessage: "A stability event could not be analyzed.",
                        recoverySuggestion: "Review the audio route and repeat the test.",
                        technicalContext: error.localizedDescription
                    )))
                }
                publish(state: .running(current: index + 1, total: plan.scheduledEventCount), plan: plan, observations: observations, failures: failures)
                if index + 1 < plan.scheduledEventCount { try await scheduler.wait(for: plan.interval) }
            }
            let samples = observations.map { StatisticalRunSample(runID: $0.id, runIndex: $0.eventIndex, delayMilliseconds: $0.delayMilliseconds, qualityLevel: $0.quality) }
            let stats = StatisticalAnalyzer().analyze(samples: samples, outcomeCount: observations.count + failures.count, failureCount: failures.count, includeMarkedOutliers: true, method: .medianAbsoluteDeviation, threshold: 3.5)
            let drift = try? driftEstimator.estimate(observations: observations.map {
                let expected = Double($0.eventIndex) * plan.interval.value * baseConfiguration.signal.sampleRate.hertz
                let observed = expected + ($0.delayMilliseconds / 1_000 * baseConfiguration.signal.sampleRate.hertz)
                return DriftObservation(eventIndex: $0.eventIndex, expectedSamplePosition: expected, observedSamplePosition: observed, confidence: $0.quality == .invalid ? 0 : 1, timestampSeconds: $0.occurredAt.timeIntervalSince(startedAt))
            })
            publish(state: .completed, plan: plan, observations: observations, failures: failures)
            return LongTermStabilityReport(plan: plan, startedAt: startedAt, completedAt: Date(), observations: observations, failures: failures, statistics: stats, drift: drift, discontinuityEventIndices: discontinuities, routeChangeDetected: routeChanged)
        } catch let error as LongTermStabilityError {
            if case .cancelled = error { publish(state: .cancelling, plan: plan, observations: observations, failures: failures) }
            else { publish(state: .failed(error.localizedDescription), plan: plan, observations: observations, failures: failures) }
            throw error
        }
    }

    public func pause() async {
        guard active else { return }
        pauseRequested = true
        if let latestSnapshot {
            let snapshot = LongTermStabilitySnapshot(state: .paused, completedEvents: latestSnapshot.completedEvents, totalEvents: latestSnapshot.totalEvents, observations: latestSnapshot.observations, failures: latestSnapshot.failures, currentDelayMilliseconds: latestSnapshot.currentDelayMilliseconds)
            self.latestSnapshot = snapshot
            handler?(snapshot)
        }
        await runner.stop()
    }

    public func resume() async throws {
        guard active, pauseRequested else { return }
        try await validateRoute()
        pauseRequested = false
    }

    public func cancel() async {
        guard active else { return }
        cancelRequested = true
        pauseRequested = false
        await runner.stop()
    }

    private func validateRoute() async throws {
        guard let frozenRoute else { return }
        do { try await deviceService.validate(route: frozenRoute) }
        catch { throw LongTermStabilityError.routeChanged(error.localizedDescription) }
    }

    private func ensureNotCancelled() throws {
        if cancelRequested { throw LongTermStabilityError.cancelled }
        try Task.checkCancellation()
    }

    private func waitWhilePaused(plan: LongTermStabilityPlan, observations: [LongTermStabilityObservation], failures: [RepeatedMeasurementRunFailure]) async throws {
        while pauseRequested {
            try ensureNotCancelled()
            try await scheduler.wait(for: .fiftyMilliseconds)
        }
    }

    private func publish(state: LongTermStabilityState, plan: LongTermStabilityPlan, observations: [LongTermStabilityObservation], failures: [RepeatedMeasurementRunFailure]) {
        let snapshot = LongTermStabilitySnapshot(state: state, completedEvents: observations.count + failures.count, totalEvents: plan.scheduledEventCount, observations: observations, failures: failures, currentDelayMilliseconds: observations.last?.delayMilliseconds)
        latestSnapshot = snapshot
        handler?(snapshot)
    }
}
