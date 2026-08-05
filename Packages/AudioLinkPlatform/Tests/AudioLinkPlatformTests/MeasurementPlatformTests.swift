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
        try await Task.sleep(for: .milliseconds(80))
        let firstState = await queue.job(first)?.state
        let secondState = await queue.job(second)?.state
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
        try await Task.sleep(for: .milliseconds(20))
        try await queue.cancel(id)
        try await Task.sleep(for: .milliseconds(20))
        let state = await queue.job(id)?.state
        XCTAssertEqual(state, .cancelled)
    }
}
