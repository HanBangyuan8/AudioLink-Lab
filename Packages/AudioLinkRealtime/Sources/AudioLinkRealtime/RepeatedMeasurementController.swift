import AudioLinkCore
import AudioLinkDSP
import Foundation

public protocol RunScheduling: Sendable {
    func wait(for duration: DurationSeconds) async throws
}

public struct RunScheduler: RunScheduling, Sendable {
    public init() {}

    public func wait(for duration: DurationSeconds) async throws {
        guard duration.value > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: .seconds(duration.value))
    }
}

public actor RepeatedMeasurementController: RepeatedMeasurementControlling {
    private let runner: any RealtimeMeasurementRunning
    private let deviceService: any AudioDeviceService
    private let scheduler: any RunScheduling
    private let analyzer: StatisticalAnalyzer
    private let progressSaver: any RepeatedMeasurementProgressSaving

    private var active = false
    private var pauseRequested = false
    private var pauseInterruptedRun = false
    private var cancelRequested = false
    private var runInProgress = false
    private var pendingTerminalError: RepeatedMeasurementError?
    private var frozenRoute: AudioRouteConfiguration?
    private var handler: RepeatedMeasurementStateHandler?
    private var latestSnapshot: RepeatedMeasurementSnapshot?

    public init(
        runner: any RealtimeMeasurementRunning,
        deviceService: any AudioDeviceService,
        scheduler: any RunScheduling = RunScheduler(),
        analyzer: StatisticalAnalyzer = .init(),
        progressSaver: any RepeatedMeasurementProgressSaving = NoopRepeatedMeasurementProgressSaver()
    ) {
        self.runner = runner
        self.deviceService = deviceService
        self.scheduler = scheduler
        self.analyzer = analyzer
        self.progressSaver = progressSaver
    }

    public func execute(
        plan: MeasurementPlan,
        baseConfiguration: RealtimeMeasurementConfiguration,
        stateHandler: RepeatedMeasurementStateHandler? = nil
    ) async throws -> RepeatedMeasurementReport {
        guard !active else { throw RepeatedMeasurementError.alreadyRunning }
        try plan.validate()
        active = true
        pauseRequested = false
        pauseInterruptedRun = false
        cancelRequested = false
        runInProgress = false
        pendingTerminalError = nil
        frozenRoute = baseConfiguration.route
        handler = stateHandler
        let startedAt = Date()
        var outcomes: [RunOutcome] = []
        var consecutiveFailures = 0
        defer {
            active = false
            pauseRequested = false
            pauseInterruptedRun = false
            cancelRequested = false
            runInProgress = false
            pendingTerminalError = nil
            frozenRoute = nil
            handler = nil
        }

        do {
            publish(
                state: .preparing,
                plan: plan,
                currentStep: nil,
                outcomes: outcomes
            )
            try await validateFrozenRoute()

            var step = 0
            while step < plan.totalScheduledStepCount {
                try await waitWhilePaused(plan: plan, outcomes: outcomes)
                try ensureNotCancelled()
                try await validateFrozenRoute()

                let isWarmUp = step < plan.warmUpRuns
                let runIndex = isWarmUp ? nil : step - plan.warmUpRuns + 1
                publish(
                    state: isWarmUp
                        ? .warmingUp(current: step + 1, total: plan.warmUpRuns)
                        : .running(current: runIndex ?? 1, total: plan.runCount),
                    plan: plan,
                    currentStep: step + 1,
                    outcomes: outcomes
                )

                let seed = seed(for: step, plan: plan, base: baseConfiguration.signal.deterministicSeed)
                let configuration = configuration(
                    for: step,
                    seed: seed,
                    isWarmUp: isWarmUp,
                    plan: plan,
                    base: baseConfiguration
                )
                let runStartedAt = Date()
                do {
                    runInProgress = true
                    let result = try await runner.measure(configuration: configuration, stateHandler: nil)
                    runInProgress = false
                    let outcome = RunOutcome(
                        id: result.id,
                        scheduledStepIndex: step + 1,
                        measuredRunIndex: runIndex,
                        isWarmUp: isWarmUp,
                        isDiscardedWarmUp: isWarmUp && plan.discardWarmUp,
                        seed: seed,
                        startedAt: runStartedAt,
                        completedAt: Date(),
                        result: result
                    )
                    outcomes.append(outcome)
                    consecutiveFailures = 0
                    try await persist(outcome, plan: plan, base: baseConfiguration, outcomes: outcomes)
                    step += 1
                } catch let failure as RealtimeMeasurementFailure where failure.code == .cancelled && pauseInterruptedRun {
                    runInProgress = false
                    pauseInterruptedRun = false
                    try await waitWhilePaused(plan: plan, outcomes: outcomes)
                    continue
                } catch is CancellationError {
                    runInProgress = false
                    throw RepeatedMeasurementError.cancelled
                } catch {
                    runInProgress = false
                    if cancelRequested { throw RepeatedMeasurementError.cancelled }
                    let failure = mapRunFailure(error)
                    let outcome = RunOutcome(
                        scheduledStepIndex: step + 1,
                        measuredRunIndex: runIndex,
                        isWarmUp: isWarmUp,
                        isDiscardedWarmUp: isWarmUp && plan.discardWarmUp,
                        seed: seed,
                        startedAt: runStartedAt,
                        completedAt: Date(),
                        failure: RepeatedMeasurementRunFailure(failure: failure)
                    )
                    outcomes.append(outcome)
                    consecutiveFailures += 1
                    try await persist(outcome, plan: plan, base: baseConfiguration, outcomes: outcomes)
                    step += 1
                    if isFatalRouteFailure(failure) {
                        throw RepeatedMeasurementError.routeChanged(
                            "The selected audio route changed during run \(step). The plan stopped before another run could use different device conditions."
                        )
                    }
                    if plan.stopOnRepeatedFailure,
                       consecutiveFailures >= plan.maximumFailureCount {
                        throw RepeatedMeasurementError.repeatedFailures(count: consecutiveFailures)
                    }
                }

                publishCurrent(plan: plan, outcomes: outcomes)
                if step < plan.totalScheduledStepCount {
                    try await waitBetweenRuns(plan: plan, outcomes: outcomes)
                }
            }

            let including = statistics(outcomes: outcomes, plan: plan, includeOutliers: true)
            let excluding = statistics(outcomes: outcomes, plan: plan, includeOutliers: false)
            publish(state: .completed, plan: plan, currentStep: nil, outcomes: outcomes)
            return RepeatedMeasurementReport(
                plan: plan,
                baseConfiguration: baseConfiguration,
                startedAt: startedAt,
                completedAt: Date(),
                outcomes: outcomes,
                statisticsIncludingOutliers: including,
                statisticsExcludingOutliers: excluding
            )
        } catch is CancellationError {
            publish(state: .cancelling, plan: plan, currentStep: nil, outcomes: outcomes)
            throw RepeatedMeasurementError.cancelled
        } catch let error as RepeatedMeasurementError {
            if error == .cancelled {
                publish(state: .cancelling, plan: plan, currentStep: nil, outcomes: outcomes)
            } else {
                publish(state: .failed(error), plan: plan, currentStep: nil, outcomes: outcomes)
            }
            throw error
        } catch {
            let mapped = RepeatedMeasurementError.routeChanged(error.localizedDescription)
            publish(state: .failed(mapped), plan: plan, currentStep: nil, outcomes: outcomes)
            throw mapped
        }
    }

    public func pause() async {
        guard active, !pauseRequested else { return }
        pauseRequested = true
        pauseInterruptedRun = runInProgress
        if let latestSnapshot {
            let paused = RepeatedMeasurementSnapshot(
                state: .paused,
                totalScheduledSteps: latestSnapshot.totalScheduledSteps,
                currentScheduledStep: latestSnapshot.currentScheduledStep,
                completedSteps: latestSnapshot.completedSteps,
                successCount: latestSnapshot.successCount,
                failureCount: latestSnapshot.failureCount,
                remainingSteps: latestSnapshot.remainingSteps,
                currentDelayMilliseconds: latestSnapshot.currentDelayMilliseconds,
                outcomes: latestSnapshot.outcomes,
                statistics: latestSnapshot.statistics
            )
            self.latestSnapshot = paused
            handler?(paused)
        }
        await runner.stop()
    }

    public func resume() async throws {
        guard active, pauseRequested else { return }
        do {
            try await validateFrozenRoute()
            pauseRequested = false
        } catch let error as RepeatedMeasurementError {
            pendingTerminalError = error
            pauseRequested = false
            throw error
        }
    }

    public func cancel() async {
        guard active else { return }
        cancelRequested = true
        pauseRequested = false
        if let latestSnapshot {
            let cancelling = RepeatedMeasurementSnapshot(
                state: .cancelling,
                totalScheduledSteps: latestSnapshot.totalScheduledSteps,
                currentScheduledStep: latestSnapshot.currentScheduledStep,
                completedSteps: latestSnapshot.completedSteps,
                successCount: latestSnapshot.successCount,
                failureCount: latestSnapshot.failureCount,
                remainingSteps: latestSnapshot.remainingSteps,
                currentDelayMilliseconds: latestSnapshot.currentDelayMilliseconds,
                outcomes: latestSnapshot.outcomes,
                statistics: latestSnapshot.statistics
            )
            self.latestSnapshot = cancelling
            handler?(cancelling)
        }
        await runner.stop()
    }

    private func waitWhilePaused(plan: MeasurementPlan, outcomes: [RunOutcome]) async throws {
        while pauseRequested {
            try ensureNotCancelled()
            publish(state: .paused, plan: plan, currentStep: latestSnapshot?.currentScheduledStep, outcomes: outcomes)
            try await scheduler.wait(for: try DurationSeconds(0.05))
        }
    }

    private func waitBetweenRuns(plan: MeasurementPlan, outcomes: [RunOutcome]) async throws {
        var remaining = plan.intervalBetweenRuns.value
        while remaining > 0 {
            try await waitWhilePaused(plan: plan, outcomes: outcomes)
            try ensureNotCancelled()
            let slice = min(remaining, 0.1)
            try await scheduler.wait(for: try DurationSeconds(slice))
            remaining -= slice
        }
    }

    private func validateFrozenRoute() async throws {
        guard let frozenRoute else {
            throw RepeatedMeasurementError.routeChanged("The original audio route is no longer available.")
        }
        do {
            try await deviceService.validate(route: frozenRoute)
        } catch {
            throw RepeatedMeasurementError.routeChanged(
                "The selected audio route changed or became unavailable. The plan stopped to avoid mixing device conditions."
            )
        }
    }

    private func ensureNotCancelled() throws {
        if let pendingTerminalError { throw pendingTerminalError }
        if cancelRequested || Task.isCancelled { throw RepeatedMeasurementError.cancelled }
    }

    private func seed(for step: Int, plan: MeasurementPlan, base: UInt64) -> UInt64 {
        switch plan.randomSeedPolicy {
        case .fixed:
            base
        case .incrementing:
            base &+ UInt64(step)
        case .deterministicPerRun:
            plan.id.uuidString.utf8.reduce(base ^ UInt64(step)) { hash, byte in
                (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
    }

    private func configuration(
        for step: Int,
        seed: UInt64,
        isWarmUp: Bool,
        plan: MeasurementPlan,
        base: RealtimeMeasurementConfiguration
    ) -> RealtimeMeasurementConfiguration {
        let original = base.signal
        let signal = TestSignalConfiguration(
            kind: plan.signalKind,
            sampleRate: original.sampleRate,
            duration: original.duration,
            startFrequencyHertz: original.startFrequencyHertz,
            endFrequencyHertz: original.endFrequencyHertz,
            amplitude: original.amplitude,
            preRollSilence: original.preRollSilence,
            postRollSilence: original.postRollSilence,
            fadeIn: original.fadeIn,
            fadeOut: original.fadeOut,
            channelCount: original.channelCount,
            deterministicSeed: seed,
            sweepDirection: original.sweepDirection,
            polarity: original.polarity,
            maximumLengthSequenceOrder: original.maximumLengthSequenceOrder
        )
        return RealtimeMeasurementConfiguration(
            route: base.route,
            signal: signal,
            preRoll: plan.preRoll,
            postRoll: plan.postRoll,
            correlation: base.correlation,
            preprocessing: base.preprocessing,
            measurementGroupID: plan.id,
            planRunSequence: step + 1,
            isWarmUpRun: isWarmUp,
            calibrationProfile: base.calibrationProfile,
            applyCalibrationOffset: base.applyCalibrationOffset
        )
    }

    private func mapRunFailure(_ error: Error) -> RealtimeMeasurementFailure {
        if let failure = error as? RealtimeMeasurementFailure { return failure }
        return RealtimeMeasurementFailure(
            code: .analysisFailed,
            userMessage: "This run did not complete.",
            recoverySuggestion: "Review the audio route and the per-run diagnostics before retrying.",
            technicalContext: error.localizedDescription
        )
    }

    private func isFatalRouteFailure(_ failure: RealtimeMeasurementFailure) -> Bool {
        switch failure.code {
        case .inputDeviceUnavailable, .outputDeviceUnavailable, .deviceDisconnected,
             .sampleRateMismatch, .invalidChannel, .incompatibleRoute:
            return true
        default:
            return false
        }
    }

    private func persist(
        _ outcome: RunOutcome,
        plan: MeasurementPlan,
        base: RealtimeMeasurementConfiguration,
        outcomes: [RunOutcome]
    ) async throws {
        do {
            try await progressSaver.record(
                outcome: outcome,
                plan: plan,
                baseConfiguration: base,
                statistics: statistics(
                    outcomes: outcomes,
                    plan: plan,
                    includeOutliers: plan.includeMarkedOutliers
                )
            )
        } catch {
            throw RepeatedMeasurementError.persistenceFailed(error.localizedDescription)
        }
    }

    private func statistics(
        outcomes: [RunOutcome],
        plan: MeasurementPlan,
        includeOutliers: Bool
    ) -> RepeatedMeasurementStatistics {
        analyzer.analyze(
            outcomes: outcomes,
            includeMarkedOutliers: includeOutliers,
            method: plan.outlierMethod,
            threshold: plan.outlierThreshold
        )
    }

    private func publishCurrent(plan: MeasurementPlan, outcomes: [RunOutcome]) {
        let measuredCompleted = outcomes.filter { !$0.isWarmUp }.count
        publish(
            state: measuredCompleted < plan.runCount
                ? .running(current: measuredCompleted + 1, total: plan.runCount)
                : .running(current: plan.runCount, total: plan.runCount),
            plan: plan,
            currentStep: nil,
            outcomes: outcomes
        )
    }

    private func publish(
        state: RepeatedMeasurementState,
        plan: MeasurementPlan,
        currentStep: Int?,
        outcomes: [RunOutcome]
    ) {
        let snapshot = RepeatedMeasurementSnapshot(
            state: state,
            totalScheduledSteps: plan.totalScheduledStepCount,
            currentScheduledStep: currentStep,
            completedSteps: outcomes.count,
            successCount: outcomes.filter(\.succeeded).count,
            failureCount: outcomes.filter { !$0.succeeded }.count,
            remainingSteps: max(0, plan.totalScheduledStepCount - outcomes.count),
            currentDelayMilliseconds: outcomes.last?.delayMilliseconds,
            outcomes: outcomes,
            statistics: statistics(
                outcomes: outcomes,
                plan: plan,
                includeOutliers: plan.includeMarkedOutliers
            )
        )
        latestSnapshot = snapshot
        handler?(snapshot)
    }
}
