import AudioLinkCore
import AudioLinkDSP
import Foundation

public struct LongTermStabilityPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let duration: DurationSeconds
    public let interval: DurationSeconds
    public let chirpDuration: DurationSeconds
    public let preRoll: DurationSeconds
    public let postRoll: DurationSeconds
    public let discontinuityThresholdMilliseconds: Double
    public let stopOnRouteChange: Bool

    public init(
        id: UUID = UUID(),
        duration: DurationSeconds,
        interval: DurationSeconds,
        chirpDuration: DurationSeconds = .oneTenthSecond,
        preRoll: DurationSeconds = .fiftyMilliseconds,
        postRoll: DurationSeconds = .oneTenthSecond,
        discontinuityThresholdMilliseconds: Double = 2,
        stopOnRouteChange: Bool = true
    ) {
        self.id = id
        self.duration = duration
        self.interval = interval
        self.chirpDuration = chirpDuration
        self.preRoll = preRoll
        self.postRoll = postRoll
        self.discontinuityThresholdMilliseconds = discontinuityThresholdMilliseconds
        self.stopOnRouteChange = stopOnRouteChange
    }

    public var scheduledEventCount: Int {
        guard interval.value > 0, duration.value >= 0 else { return 0 }
        return max(1, Int(floor(duration.value / interval.value)) + 1)
    }

    public func validate() throws {
        guard duration.value.isFinite, duration.value > 0,
              duration.value <= 86_400,
              interval.value.isFinite, interval.value > 0,
              interval.value <= 3_600,
              chirpDuration.value.isFinite, chirpDuration.value > 0,
              preRoll.value.isFinite, preRoll.value >= 0,
              postRoll.value.isFinite, postRoll.value >= 0,
              discontinuityThresholdMilliseconds.isFinite,
              discontinuityThresholdMilliseconds >= 0 else {
            throw LongTermStabilityError.invalidPlan("Duration, interval and chirp timing must be finite and positive where applicable.")
        }
    }
}

public enum LongTermStabilityState: Equatable, Sendable {
    case preparing
    case running(current: Int, total: Int)
    case paused
    case cancelling
    case completed
    case terminated(reason: String)
    case failed(String)
}

public struct LongTermStabilityObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let eventIndex: Int
    public let occurredAt: Date
    public let delayMilliseconds: Double
    public let quality: MeasurementQualityLevel
    public let discontinuityMilliseconds: Double?
    public let route: AudioRouteConfiguration

    public init(
        id: UUID = UUID(),
        eventIndex: Int,
        occurredAt: Date,
        delayMilliseconds: Double,
        quality: MeasurementQualityLevel,
        discontinuityMilliseconds: Double? = nil,
        route: AudioRouteConfiguration
    ) {
        self.id = id
        self.eventIndex = eventIndex
        self.occurredAt = occurredAt
        self.delayMilliseconds = delayMilliseconds
        self.quality = quality
        self.discontinuityMilliseconds = discontinuityMilliseconds
        self.route = route
    }
}

public struct LongTermStabilityReport: Equatable, Sendable {
    public let plan: LongTermStabilityPlan
    public let startedAt: Date
    public let completedAt: Date
    public let observations: [LongTermStabilityObservation]
    public let failures: [RepeatedMeasurementRunFailure]
    public let statistics: RepeatedMeasurementStatistics
    public let drift: DriftEstimate?
    public let discontinuityEventIndices: [Int]
    public let routeChangeDetected: Bool

    public init(
        plan: LongTermStabilityPlan,
        startedAt: Date,
        completedAt: Date,
        observations: [LongTermStabilityObservation],
        failures: [RepeatedMeasurementRunFailure],
        statistics: RepeatedMeasurementStatistics,
        drift: DriftEstimate?,
        discontinuityEventIndices: [Int],
        routeChangeDetected: Bool
    ) {
        self.plan = plan
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.observations = observations
        self.failures = failures
        self.statistics = statistics
        self.drift = drift
        self.discontinuityEventIndices = discontinuityEventIndices
        self.routeChangeDetected = routeChangeDetected
    }
}

public struct LongTermStabilitySnapshot: Equatable, Sendable {
    public let state: LongTermStabilityState
    public let completedEvents: Int
    public let totalEvents: Int
    public let observations: [LongTermStabilityObservation]
    public let failures: [RepeatedMeasurementRunFailure]
    public let currentDelayMilliseconds: Double?

    public init(
        state: LongTermStabilityState,
        completedEvents: Int,
        totalEvents: Int,
        observations: [LongTermStabilityObservation],
        failures: [RepeatedMeasurementRunFailure],
        currentDelayMilliseconds: Double?
    ) {
        self.state = state
        self.completedEvents = completedEvents
        self.totalEvents = totalEvents
        self.observations = observations
        self.failures = failures
        self.currentDelayMilliseconds = currentDelayMilliseconds
    }
}

public enum LongTermStabilityError: Error, LocalizedError, Equatable, Sendable {
    case invalidPlan(String)
    case alreadyRunning
    case cancelled
    case routeChanged(String)
    case interrupted(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPlan(message): message
        case .alreadyRunning: "A long-term stability test is already running."
        case .cancelled: "The long-term stability test was cancelled."
        case let .routeChanged(message): message
        case let .interrupted(message): message
        }
    }
}

public typealias LongTermStabilityStateHandler = @Sendable (LongTermStabilitySnapshot) -> Void

public protocol LongTermStabilityControlling: Sendable {
    func execute(
        plan: LongTermStabilityPlan,
        baseConfiguration: RealtimeMeasurementConfiguration,
        stateHandler: LongTermStabilityStateHandler?
    ) async throws -> LongTermStabilityReport
    func pause() async
    func resume() async throws
    func cancel() async
}
