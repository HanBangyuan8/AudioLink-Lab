import AudioLinkCore
import AudioLinkNetworking
import Foundation

public enum NodeRole: String, Codable, CaseIterable, Sendable { case coordinator, player, recorder, observer, relay, localAnalyzer }
public enum NodeHealth: String, Codable, CaseIterable, Sendable { case unknown, healthy, warning, degraded, failed, disconnected }
public enum DistributedNodeState: String, Codable, CaseIterable, Sendable { case invited, connected, paired, capabilityConfirmed, configurationAccepted, preparing, ready, armed, running, uploading, analyzing, completed, failed, disconnected }

public struct NodeCapability: Codable, Equatable, Sendable {
    public let platform: String
    public let appVersion: String
    public let protocolVersion: String
    public let sampleRatesHertz: [Double]
    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let microphonePermission: Bool
    public let speakerAvailable: Bool
    public let localStorageBytes: Int64
    public let batteryFraction: Double?
    public let thermalState: String?
    public let networkInterface: String?
    public let audioRoutes: [String]
    public let maximumRecordingDurationSeconds: Double
    public init(platform: String, appVersion: String, protocolVersion: String, sampleRatesHertz: [Double], inputChannelCount: Int, outputChannelCount: Int, microphonePermission: Bool, speakerAvailable: Bool, localStorageBytes: Int64, batteryFraction: Double? = nil, thermalState: String? = nil, networkInterface: String? = nil, audioRoutes: [String] = [], maximumRecordingDurationSeconds: Double) {
        self.platform = platform; self.appVersion = appVersion; self.protocolVersion = protocolVersion; self.sampleRatesHertz = sampleRatesHertz; self.inputChannelCount = inputChannelCount; self.outputChannelCount = outputChannelCount; self.microphonePermission = microphonePermission; self.speakerAvailable = speakerAvailable; self.localStorageBytes = localStorageBytes; self.batteryFraction = batteryFraction; self.thermalState = thermalState; self.networkInterface = networkInterface; self.audioRoutes = audioRoutes; self.maximumRecordingDurationSeconds = maximumRecordingDurationSeconds
    }
}

public struct MeasurementNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public var roles: Set<NodeRole>
    public var capability: NodeCapability?
    public var health: NodeHealth
    public var state: DistributedNodeState
    public var rttNanoseconds: UInt64?
    public var lastHeartbeat: Date?
    public init(id: UUID = UUID(), displayName: String, roles: Set<NodeRole>, capability: NodeCapability? = nil, health: NodeHealth = .unknown, state: DistributedNodeState = .invited, rttNanoseconds: UInt64? = nil, lastHeartbeat: Date? = nil) { self.id = id; self.displayName = displayName; self.roles = roles; self.capability = capability; self.health = health; self.state = state; self.rttNanoseconds = rttNanoseconds; self.lastHeartbeat = lastHeartbeat }
}

public struct NodeAssignment: Codable, Equatable, Sendable { public let nodeID: UUID; public let roles: Set<NodeRole>; public let inputChannel: Int?; public let outputChannel: Int?; public init(nodeID: UUID, roles: Set<NodeRole>, inputChannel: Int? = nil, outputChannel: Int? = nil) { self.nodeID = nodeID; self.roles = roles; self.inputChannel = inputChannel; self.outputChannel = outputChannel } }
public enum NodeFailurePolicy: String, Codable, CaseIterable, Sendable { case failEntireSession, continueWithAvailableNodes, retryFailedNodes, skipNode, waitForReconnect }
public struct DistributedSessionPlan: Codable, Equatable, Sendable {
    public let id: UUID
    public let sampleRateHertz: Double
    public let durationSeconds: Double
    public let assignments: [NodeAssignment]
    public let failurePolicy: NodeFailurePolicy
    public let startLeadNanoseconds: UInt64
    public let retainNodeFiles: Bool
    public init(id: UUID = UUID(), sampleRateHertz: Double, durationSeconds: Double, assignments: [NodeAssignment], failurePolicy: NodeFailurePolicy = .failEntireSession, startLeadNanoseconds: UInt64 = 2_000_000_000, retainNodeFiles: Bool = true) { self.id = id; self.sampleRateHertz = sampleRateHertz; self.durationSeconds = durationSeconds; self.assignments = assignments; self.failurePolicy = failurePolicy; self.startLeadNanoseconds = startLeadNanoseconds; self.retainNodeFiles = retainNodeFiles }
}

public struct SynchronizationUncertainty: Codable, Equatable, Sendable {
    public let clockOffsetNanoseconds: Double
    public let confidenceIntervalNanoseconds: Double
    public let rttMinimumNanoseconds: UInt64?
    public let rttMedianNanoseconds: UInt64?
    public let driftContributionNanoseconds: Double
    public let observationStalenessNanoseconds: UInt64?
    public let schedulingUncertaintyNanoseconds: Double
    public let audioCallbackUncertaintyNanoseconds: Double
    public let finalAcousticAlignmentUncertaintyNanoseconds: Double
    public let networkAsymmetryWarning: Bool
    public init(clockOffsetNanoseconds: Double, confidenceIntervalNanoseconds: Double, rttMinimumNanoseconds: UInt64?, rttMedianNanoseconds: UInt64?, driftContributionNanoseconds: Double = 0, observationStalenessNanoseconds: UInt64? = nil, schedulingUncertaintyNanoseconds: Double = 0, audioCallbackUncertaintyNanoseconds: Double = 0, finalAcousticAlignmentUncertaintyNanoseconds: Double = 0, networkAsymmetryWarning: Bool = false) { self.clockOffsetNanoseconds = clockOffsetNanoseconds; self.confidenceIntervalNanoseconds = confidenceIntervalNanoseconds; self.rttMinimumNanoseconds = rttMinimumNanoseconds; self.rttMedianNanoseconds = rttMedianNanoseconds; self.driftContributionNanoseconds = driftContributionNanoseconds; self.observationStalenessNanoseconds = observationStalenessNanoseconds; self.schedulingUncertaintyNanoseconds = schedulingUncertaintyNanoseconds; self.audioCallbackUncertaintyNanoseconds = audioCallbackUncertaintyNanoseconds; self.finalAcousticAlignmentUncertaintyNanoseconds = finalAcousticAlignmentUncertaintyNanoseconds; self.networkAsymmetryWarning = networkAsymmetryWarning }
}

public struct NodeClockModel: Codable, Equatable, Sendable {
    public let nodeID: UUID
    public let observations: [ClockObservation]
    public let offsetEstimateNanoseconds: Double?
    public let driftPPM: Double?
    public let uncertainty: SynchronizationUncertainty
    public let observedAt: Date
    public init(nodeID: UUID, observations: [ClockObservation], offsetEstimateNanoseconds: Double?, driftPPM: Double?, uncertainty: SynchronizationUncertainty, observedAt: Date = Date()) { self.nodeID = nodeID; self.observations = observations; self.offsetEstimateNanoseconds = offsetEstimateNanoseconds; self.driftPPM = driftPPM; self.uncertainty = uncertainty; self.observedAt = observedAt }
}

public struct DistributedSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let plan: DistributedSessionPlan
    public var nodes: [MeasurementNode]
    public var clocks: [UUID: NodeClockModel]
    public var state: DistributedNodeState
    public let createdAt: Date
    public init(id: UUID = UUID(), plan: DistributedSessionPlan, nodes: [MeasurementNode] = [], clocks: [UUID: NodeClockModel] = [:], state: DistributedNodeState = .invited, createdAt: Date = Date()) { self.id = id; self.plan = plan; self.nodes = nodes; self.clocks = clocks; self.state = state; self.createdAt = createdAt }
}

public struct UncertaintyBudget: Codable, Equatable, Sendable {
    public let componentsNanoseconds: [String: Double]
    public let combinedStandardUncertaintyNanoseconds: Double
    public init(componentsNanoseconds: [String: Double]) { self.componentsNanoseconds = componentsNanoseconds; self.combinedStandardUncertaintyNanoseconds = sqrt(componentsNanoseconds.values.reduce(0) { $0 + $1 * $1 }) }
}

public struct DistributedMeasurementResult: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let acousticArrivalNanosecondsByNode: [UUID: Double]
    public let clockModels: [UUID: NodeClockModel]
    public let uncertaintyBudget: UncertaintyBudget
    public let missingNodes: [UUID]
    public let explanation: String
    public init(sessionID: UUID, acousticArrivalNanosecondsByNode: [UUID: Double], clockModels: [UUID: NodeClockModel], uncertaintyBudget: UncertaintyBudget, missingNodes: [UUID] = [], explanation: String) { self.sessionID = sessionID; self.acousticArrivalNanosecondsByNode = acousticArrivalNanosecondsByNode; self.clockModels = clockModels; self.uncertaintyBudget = uncertaintyBudget; self.missingNodes = missingNodes; self.explanation = explanation }
}
