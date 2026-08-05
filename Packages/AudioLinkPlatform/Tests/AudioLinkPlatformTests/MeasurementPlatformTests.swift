import XCTest
@testable import AudioLinkPlatform

final class MeasurementPlatformTests: XCTestCase {
    func testBuiltInDescriptorsAreUniqueAndHeadless() {
        let descriptors = BuiltInMeasurementModules.descriptors
        XCTAssertEqual(Set(descriptors.map(\.identifier)).count, descriptors.count)
        XCTAssertTrue(descriptors.allSatisfy(\.supportsHeadlessMode))
    }

    func testQueueSerializesSharedResources() async throws {
        let queue = MeasurementJobQueue()
        let descriptor = MeasurementModuleDescriptor(identifier: "test", name: "Test")
        let module = AnyMeasurementModule(descriptor: descriptor) { context in
            try await Task.sleep(for: .milliseconds(20))
            return MeasurementResultEnvelope(jobID: context.jobID, provenance: MeasurementProvenance(moduleIdentifier: "test", moduleVersion: "1", algorithmVersion: "test", appVersion: "test"), configuration: .object([:]), payload: .object(["ok": .bool(true)]))
        }
        let first = await queue.submit(module: module, configuration: .object([:]), resourceKeys: ["device:one"])
        let second = await queue.submit(module: module, configuration: .object([:]), resourceKeys: ["device:one"])
        let firstState = try await waitForTerminalState(of: first, in: queue)
        let secondState = try await waitForTerminalState(of: second, in: queue)
        XCTAssertEqual(firstState, .completed)
        XCTAssertEqual(secondState, .completed)
    }

    func testCancellationIsObservable() async throws {
        let queue = MeasurementJobQueue()
        let descriptor = MeasurementModuleDescriptor(identifier: "slow", name: "Slow")
        let module = AnyMeasurementModule(descriptor: descriptor) { context in
            try await Task.sleep(for: .seconds(5))
            return MeasurementResultEnvelope(jobID: context.jobID, provenance: MeasurementProvenance(moduleIdentifier: "slow", moduleVersion: "1", algorithmVersion: "test", appVersion: "test"), configuration: .object([:]), payload: .null)
        }
        let id = await queue.submit(module: module, configuration: .object([:]), resourceKeys: [])
        _ = try await waitForState(of: id, expected: .running, in: queue)
        try await queue.cancel(id)
        let state = try await waitForTerminalState(of: id, in: queue)
        XCTAssertEqual(state, .cancelled)
    }

    private func waitForState(
        of id: UUID,
        expected: MeasurementJobState,
        in queue: MeasurementJobQueue,
        timeout: Duration = .seconds(2)
    ) async throws -> MeasurementJobState {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let state = await queue.job(id)?.state, state == expected { return state }
            try await Task.sleep(for: .milliseconds(5))
        }
        let state = await queue.job(id)?.state
        return try XCTUnwrap(state, "Timed out waiting for \(expected.rawValue)")
    }

    private func waitForTerminalState(
        of id: UUID,
        in queue: MeasurementJobQueue,
        timeout: Duration = .seconds(2)
    ) async throws -> MeasurementJobState {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let state = await queue.job(id)?.state,
               [.completed, .failed, .cancelled].contains(state) { return state }
            try await Task.sleep(for: .milliseconds(5))
        }
        let state = await queue.job(id)?.state
        return try XCTUnwrap(state, "Timed out waiting for terminal state")
    }
}
