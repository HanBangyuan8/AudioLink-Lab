import AudioLinkDistributed
import AudioLinkNetworking
import XCTest

final class DistributedTests: XCTestCase {
    func testClockSummaryAndBudget() throws {
        let node = UUID(); let observations = try [ClockObservation(t1: 0, t2: 100, t3: 110, t4: 210), ClockObservation(t1: 1_000, t2: 1_100, t3: 1_110, t4: 1_210)]
        let model = DistributedClockMath.summarize(nodeID: node, observations: observations)
        XCTAssertEqual(model.offsetEstimateNanoseconds ?? .nan, 0, accuracy: 0.001)
        let budget = DistributedClockMath.uncertaintyBudget(clock: model, schedulingNanoseconds: 10, audioNanoseconds: 20)
        XCTAssertGreaterThan(budget.combinedStandardUncertaintyNanoseconds, 0)
    }
    func testCoordinatorNeverStartsBeforeAllReady() async throws {
        let n1 = UUID(); let n2 = UUID(); let plan = DistributedSessionPlan(sampleRateHertz: 48_000, durationSeconds: 1, assignments: [.init(nodeID: n1, roles: [.recorder]), .init(nodeID: n2, roles: [.recorder])])
        let coordinator = DistributedSessionCoordinator(session: DistributedSession(plan: plan, nodes: [.init(id: n1, displayName: "A", roles: [.recorder], state: .ready), .init(id: n2, displayName: "B", roles: [.recorder], state: .preparing)]))
        do { try await coordinator.prepare(); XCTFail("Expected readiness failure") } catch let error as DistributedSessionError { XCTAssertEqual(error, .nodesNotReady([n2])) }
    }
    func testStaleSessionIsRejected() async throws {
        let n = UUID(); let plan = DistributedSessionPlan(sampleRateHertz: 48_000, durationSeconds: 1, assignments: [.init(nodeID: n, roles: [.recorder])]); let session = DistributedSession(plan: plan, nodes: [.init(id: n, displayName: "A", roles: [.recorder], state: .ready)]); let coordinator = DistributedSessionCoordinator(session: session)
        do { try await coordinator.handleMessage(sessionID: UUID(), nodeID: n, state: .running); XCTFail("Expected stale session") } catch let error as DistributedSessionError { XCTAssertEqual(error, .staleSession) }
    }
    func testUncertaintySeparatesAcousticAndNetworkInputs() {
        let budget = UncertaintyBudget(componentsNanoseconds: ["clock": 5, "networkScheduling": 10, "audioCallback": 20, "drift": 2]); XCTAssertEqual(budget.componentsNanoseconds["networkScheduling"], 10)
    }
    func testCapabilityMismatchIsExplicit() async throws {
        let nodeID = UUID(); let plan = DistributedSessionPlan(sampleRateHertz: 96_000, durationSeconds: 10, assignments: [.init(nodeID: nodeID, roles: [.recorder])])
        let capability = NodeCapability(platform: "iPhone", appVersion: "1", protocolVersion: "1", sampleRatesHertz: [48_000], inputChannelCount: 1, outputChannelCount: 0, microphonePermission: true, speakerAvailable: false, localStorageBytes: 1_000, maximumRecordingDurationSeconds: 1)
        let session = DistributedSession(plan: plan, nodes: [.init(id: nodeID, displayName: "Recorder", roles: [.recorder], capability: capability)])
        let coordinator = DistributedSessionCoordinator(session: session)
        do { try await coordinator.confirmCapabilities(nodeID); XCTFail("Expected mismatch") } catch let error as DistributedSessionError { if case .capabilityMismatch = error { } else { XCTFail("Unexpected error: \(error)") } }
    }
}
