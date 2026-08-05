import AudioLinkNetworking
import Foundation

public enum DistributedClockMath {
    public static func summarize(nodeID: UUID, observations: [ClockObservation], now: UInt64? = nil, driftPPM: Double? = nil) -> NodeClockModel {
        let offsets = observations.map { Double($0.offsetNanoseconds) }.sorted()
        let rtts = observations.map(\.roundTripTimeNanoseconds).sorted()
        let medianOffset = offsets.isEmpty ? nil : offsets[offsets.count / 2]
        let medianRTT = rtts.isEmpty ? nil : rtts[rtts.count / 2]
        let minimumRTT = rtts.min()
        let mad = offsets.isEmpty ? 0 : offsets.map { abs($0 - (medianOffset ?? 0)) }.sorted()[offsets.count / 2]
        let age = now.map { current in observations.last.map { current >= $0.t4 ? current - $0.t4 : 0 } }
        let uncertainty = SynchronizationUncertainty(clockOffsetNanoseconds: medianOffset ?? 0, confidenceIntervalNanoseconds: max(1, mad * 1.4826), rttMinimumNanoseconds: minimumRTT, rttMedianNanoseconds: medianRTT, driftContributionNanoseconds: 0, observationStalenessNanoseconds: age ?? nil, schedulingUncertaintyNanoseconds: Double(medianRTT ?? 0) / 2, audioCallbackUncertaintyNanoseconds: 0, finalAcousticAlignmentUncertaintyNanoseconds: max(1, mad * 1.4826), networkAsymmetryWarning: medianRTT.map { $0 > (minimumRTT ?? $0) * 2 } ?? false)
        return NodeClockModel(nodeID: nodeID, observations: observations, offsetEstimateNanoseconds: medianOffset, driftPPM: driftPPM, uncertainty: uncertainty)
    }

    public static func uncertaintyBudget(clock: NodeClockModel, schedulingNanoseconds: Double, audioNanoseconds: Double) -> UncertaintyBudget {
        UncertaintyBudget(componentsNanoseconds: ["clock": clock.uncertainty.confidenceIntervalNanoseconds, "networkScheduling": schedulingNanoseconds, "audioCallback": audioNanoseconds, "drift": clock.uncertainty.driftContributionNanoseconds])
    }
}

public actor DistributedSessionCoordinator {
    public private(set) var session: DistributedSession
    private var startIssued = false
    public init(session: DistributedSession) { self.session = session }
    public func addNode(_ node: MeasurementNode) throws {
        guard !session.nodes.contains(where: { $0.id == node.id }) else { return }
        guard session.plan.assignments.contains(where: { $0.nodeID == node.id }) else { throw DistributedSessionError.unassignedNode(node.id) }
        session.nodes.append(node)
    }
    public func updateNode(_ nodeID: UUID, state: DistributedNodeState? = nil, health: NodeHealth? = nil, capability: NodeCapability? = nil) throws {
        guard let index = session.nodes.firstIndex(where: { $0.id == nodeID }) else { throw DistributedSessionError.nodeNotFound(nodeID) }
        if let state { session.nodes[index].state = state }
        if let health { session.nodes[index].health = health }
        if let capability { session.nodes[index].capability = capability }
    }
    public func confirmCapabilities(_ nodeID: UUID) throws {
        guard let index = session.nodes.firstIndex(where: { $0.id == nodeID }), let capability = session.nodes[index].capability else { throw DistributedSessionError.capabilityMismatch(nodeID, "The node has not advertised capabilities.") }
        guard capability.sampleRatesHertz.contains(where: { abs($0 - session.plan.sampleRateHertz) < 0.5 }) else { throw DistributedSessionError.capabilityMismatch(nodeID, "The requested sample rate is not advertised.") }
        guard capability.maximumRecordingDurationSeconds >= session.plan.durationSeconds else { throw DistributedSessionError.capabilityMismatch(nodeID, "The requested duration exceeds the node's recording limit.") }
        guard let assignment = session.plan.assignments.first(where: { $0.nodeID == nodeID }) else { throw DistributedSessionError.unassignedNode(nodeID) }
        if assignment.roles.contains(.recorder) && (!capability.microphonePermission || capability.inputChannelCount <= (assignment.inputChannel ?? 0)) { throw DistributedSessionError.capabilityMismatch(nodeID, "The assigned recorder input is unavailable or permission is denied.") }
        if assignment.roles.contains(.player) && (!capability.speakerAvailable || capability.outputChannelCount <= (assignment.outputChannel ?? 0)) { throw DistributedSessionError.capabilityMismatch(nodeID, "The assigned player output is unavailable.") }
        session.nodes[index].state = .capabilityConfirmed
    }
    public func setClock(_ model: NodeClockModel) throws { guard session.nodes.contains(where: { $0.id == model.nodeID }) else { throw DistributedSessionError.nodeNotFound(model.nodeID) }; session.clocks[model.nodeID] = model }
    public func prepare() throws {
        guard !session.nodes.isEmpty else { throw DistributedSessionError.noNodes }
        guard session.nodes.allSatisfy({ $0.state == .ready || $0.state == .armed }) else { throw DistributedSessionError.nodesNotReady(session.nodes.filter { $0.state != .ready && $0.state != .armed }.map(\.id)) }
        session.nodes.indices.forEach { session.nodes[$0].state = .armed }; session.state = .armed
    }
    public func begin() throws {
        guard session.state == .armed, !startIssued else { throw DistributedSessionError.invalidState }
        startIssued = true; session.state = .running; session.nodes.indices.forEach { session.nodes[$0].state = .running }
    }
    public func cancel() { session.state = .failed; session.nodes.indices.forEach { session.nodes[$0].state = .failed } }
    public func handleMessage(sessionID: UUID, nodeID: UUID, state: DistributedNodeState) throws {
        guard sessionID == session.id else { throw DistributedSessionError.staleSession }
        try updateNode(nodeID, state: state)
    }
}

public enum DistributedSessionError: Error, Codable, Equatable, Sendable, LocalizedError {
    case noNodes, nodeNotFound(UUID), unassignedNode(UUID), capabilityMismatch(UUID, String), nodesNotReady([UUID]), staleSession, invalidState
    public var errorDescription: String? { switch self { case .noNodes: "No nodes are assigned."; case let .nodeNotFound(id): "Node \(id) is not part of the session."; case let .unassignedNode(id): "Node \(id) is not assigned in the plan."; case let .capabilityMismatch(id, reason): "Node \(id) cannot satisfy the plan: \(reason)"; case let .nodesNotReady(ids): "Nodes are not ready: \(ids)."; case .staleSession: "Message belongs to a different session."; case .invalidState: "The distributed session is not ready for this operation." } }
}
