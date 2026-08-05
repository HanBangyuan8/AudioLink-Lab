import AudioLinkCore
import AudioLinkDSP
import Foundation

public enum RandomSeedPolicy: String, Codable, CaseIterable, Sendable {
    /// Use the signal configuration seed for every run.
    case fixed
    /// Add the zero-based scheduled step index to the base seed.
    case incrementing
    /// Derive a stable per-run seed from plan ID, base seed, and step index.
    case deterministicPerRun
}

public struct MeasurementPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let runCount: Int
    public let intervalBetweenRuns: DurationSeconds
    public let warmUpRuns: Int
    public let discardWarmUp: Bool
    public let stopOnRepeatedFailure: Bool
    public let maximumFailureCount: Int
    public let preRoll: DurationSeconds
    public let postRoll: DurationSeconds
    public let signalKind: SignalKind
    public let randomSeedPolicy: RandomSeedPolicy
    public let outlierMethod: OutlierDetectionMethod
    public let outlierThreshold: Double
    public let includeMarkedOutliers: Bool

    public init(
        id: UUID = UUID(),
        runCount: Int,
        intervalBetweenRuns: DurationSeconds,
        warmUpRuns: Int = 1,
        discardWarmUp: Bool = true,
        stopOnRepeatedFailure: Bool = true,
        maximumFailureCount: Int = 3,
        preRoll: DurationSeconds,
        postRoll: DurationSeconds,
        signalKind: SignalKind,
        randomSeedPolicy: RandomSeedPolicy = .fixed,
        outlierMethod: OutlierDetectionMethod = .medianAbsoluteDeviation,
        outlierThreshold: Double = 3.5,
        includeMarkedOutliers: Bool = true
    ) {
        self.id = id
        self.runCount = runCount
        self.intervalBetweenRuns = intervalBetweenRuns
        self.warmUpRuns = warmUpRuns
        self.discardWarmUp = discardWarmUp
        self.stopOnRepeatedFailure = stopOnRepeatedFailure
        self.maximumFailureCount = maximumFailureCount
        self.preRoll = preRoll
        self.postRoll = postRoll
        self.signalKind = signalKind
        self.randomSeedPolicy = randomSeedPolicy
        self.outlierMethod = outlierMethod
        self.outlierThreshold = outlierThreshold
        self.includeMarkedOutliers = includeMarkedOutliers
    }

    public var totalScheduledStepCount: Int { warmUpRuns + runCount }

    public func validate() throws {
        guard (1...1_000).contains(runCount) else {
            throw RepeatedMeasurementError.invalidPlan("Run count must be between 1 and 1000.")
        }
        guard (0...100).contains(warmUpRuns) else {
            throw RepeatedMeasurementError.invalidPlan("Warm-up count must be between 0 and 100.")
        }
        guard maximumFailureCount > 0 else {
            throw RepeatedMeasurementError.invalidPlan("Maximum failure count must be greater than zero.")
        }
        guard outlierThreshold.isFinite, outlierThreshold > 0 else {
            throw RepeatedMeasurementError.invalidPlan("Outlier threshold must be finite and greater than zero.")
        }
        guard intervalBetweenRuns.value.isFinite,
              preRoll.value.isFinite,
              postRoll.value.isFinite else {
            throw RepeatedMeasurementError.invalidPlan("Plan timing values must be finite.")
        }
    }
}

public struct RepeatedMeasurementRunFailure: Codable, Equatable, Sendable {
    public let failure: RealtimeMeasurementFailure
    public let occurredAt: Date

    public init(failure: RealtimeMeasurementFailure, occurredAt: Date = Date()) {
        self.failure = failure
        self.occurredAt = occurredAt
    }
}

public struct RunOutcome: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let scheduledStepIndex: Int
    public let measuredRunIndex: Int?
    public let isWarmUp: Bool
    public let isDiscardedWarmUp: Bool
    public let seed: UInt64
    public let startedAt: Date
    public let completedAt: Date
    public let result: RealtimeMeasurementResult?
    public let failure: RepeatedMeasurementRunFailure?

    public init(
        id: UUID = UUID(),
        scheduledStepIndex: Int,
        measuredRunIndex: Int?,
        isWarmUp: Bool,
        isDiscardedWarmUp: Bool,
        seed: UInt64,
        startedAt: Date,
        completedAt: Date,
        result: RealtimeMeasurementResult? = nil,
        failure: RepeatedMeasurementRunFailure? = nil
    ) {
        self.id = id
        self.scheduledStepIndex = scheduledStepIndex
        self.measuredRunIndex = measuredRunIndex
        self.isWarmUp = isWarmUp
        self.isDiscardedWarmUp = isDiscardedWarmUp
        self.seed = seed
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.result = result
        self.failure = failure
    }

    public var succeeded: Bool { result != nil }
    public var delayMilliseconds: Double? { result?.assessment.delay?.fractionalMilliseconds }
    public var qualityLevel: MeasurementQualityLevel? { result?.assessment.quality.level }
}

public enum RepeatedMeasurementState: Equatable, Sendable {
    case preparing
    case warmingUp(current: Int, total: Int)
    case running(current: Int, total: Int)
    case paused
    case cancelling
    case completed
    case failed(RepeatedMeasurementError)
}

public struct RepeatedMeasurementSnapshot: Equatable, Sendable {
    public let state: RepeatedMeasurementState
    public let totalScheduledSteps: Int
    public let currentScheduledStep: Int?
    public let completedSteps: Int
    public let successCount: Int
    public let failureCount: Int
    public let remainingSteps: Int
    public let currentDelayMilliseconds: Double?
    public let outcomes: [RunOutcome]
    public let statistics: RepeatedMeasurementStatistics?

    public init(
        state: RepeatedMeasurementState,
        totalScheduledSteps: Int,
        currentScheduledStep: Int?,
        completedSteps: Int,
        successCount: Int,
        failureCount: Int,
        remainingSteps: Int,
        currentDelayMilliseconds: Double?,
        outcomes: [RunOutcome],
        statistics: RepeatedMeasurementStatistics?
    ) {
        self.state = state
        self.totalScheduledSteps = totalScheduledSteps
        self.currentScheduledStep = currentScheduledStep
        self.completedSteps = completedSteps
        self.successCount = successCount
        self.failureCount = failureCount
        self.remainingSteps = remainingSteps
        self.currentDelayMilliseconds = currentDelayMilliseconds
        self.outcomes = outcomes
        self.statistics = statistics
    }
}

public struct RepeatedMeasurementReport: Equatable, Sendable {
    public let plan: MeasurementPlan
    public let baseConfiguration: RealtimeMeasurementConfiguration
    public let startedAt: Date
    public let completedAt: Date
    public let outcomes: [RunOutcome]
    public let statisticsIncludingOutliers: RepeatedMeasurementStatistics
    public let statisticsExcludingOutliers: RepeatedMeasurementStatistics

    public init(
        plan: MeasurementPlan,
        baseConfiguration: RealtimeMeasurementConfiguration,
        startedAt: Date,
        completedAt: Date,
        outcomes: [RunOutcome],
        statisticsIncludingOutliers: RepeatedMeasurementStatistics,
        statisticsExcludingOutliers: RepeatedMeasurementStatistics
    ) {
        self.plan = plan
        self.baseConfiguration = baseConfiguration
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcomes = outcomes
        self.statisticsIncludingOutliers = statisticsIncludingOutliers
        self.statisticsExcludingOutliers = statisticsExcludingOutliers
    }
}

public enum RepeatedMeasurementError: Error, Codable, Equatable, Sendable {
    case invalidPlan(String)
    case alreadyRunning
    case cancelled
    case routeChanged(String)
    case repeatedFailures(count: Int)
    case persistenceFailed(String)
}

extension RepeatedMeasurementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidPlan(message): message
        case .alreadyRunning: "A repeated measurement plan is already running."
        case .cancelled: "The repeated measurement plan was cancelled."
        case let .routeChanged(message): message
        case let .repeatedFailures(count): "The plan stopped after \(count) consecutive failed runs."
        case let .persistenceFailed(message): message
        }
    }
}

public typealias RepeatedMeasurementStateHandler = @Sendable (RepeatedMeasurementSnapshot) -> Void

public protocol RepeatedMeasurementControlling: Sendable {
    func execute(
        plan: MeasurementPlan,
        baseConfiguration: RealtimeMeasurementConfiguration,
        stateHandler: RepeatedMeasurementStateHandler?
    ) async throws -> RepeatedMeasurementReport
    func pause() async
    func resume() async throws
    func cancel() async
}

public protocol RepeatedMeasurementProgressSaving: Sendable {
    func record(
        outcome: RunOutcome,
        plan: MeasurementPlan,
        baseConfiguration: RealtimeMeasurementConfiguration,
        statistics: RepeatedMeasurementStatistics?
    ) async throws
}

public struct NoopRepeatedMeasurementProgressSaver: RepeatedMeasurementProgressSaving {
    public init() {}
    public func record(
        outcome: RunOutcome,
        plan: MeasurementPlan,
        baseConfiguration: RealtimeMeasurementConfiguration,
        statistics: RepeatedMeasurementStatistics?
    ) async throws {}
}
