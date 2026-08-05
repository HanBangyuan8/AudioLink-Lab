import AudioLinkCore
import XCTest
@testable import AudioLinkRealtime

final class CoreAudioHALProfilerTests: XCTestCase {
    func testSnapshotReadsInputAndOutputWithScopedProperties() async throws {
        let provider = MockHALProvider()
        provider.add(42, HALSelector.name, .string("Interface"))
        provider.add(42, HALSelector.manufacturer, .string("Acme"))
        provider.add(42, HALSelector.deviceUID, .string("acme.uid"))
        provider.add(42, HALSelector.nominalSampleRate, .double(48_000), scope: .global)
        provider.add(42, HALSelector.streamConfiguration, .bytes(bufferList(channelCount: 2)), scope: .input)
        provider.add(42, HALSelector.streamConfiguration, .bytes(bufferList(channelCount: 2)), scope: .output)
        let profiler = AudioDeviceProfiler(provider: provider)
        let snapshot = try await profiler.snapshot(objectID: 42)
        XCTAssertEqual(snapshot.name, "Interface")
        XCTAssertEqual(snapshot.inputChannelCount, 2)
        XCTAssertEqual(snapshot.outputChannelCount, 2)
        XCTAssertEqual(snapshot.nominalSampleRate, .hz48000)
        XCTAssertEqual(snapshot.streams.map(\.scope), [.input, .output])
    }

    func testAudioValueRangeUsesDoubleBounds() async throws {
        let provider = MockHALProvider(); provider.add(10, HALSelector.name, .string("Range")); provider.add(10, HALSelector.bufferFrameSizeRange, .bytes(doubleRange(minimum: 32, maximum: 1024)))
        let snapshot = try await AudioDeviceProfiler(provider: provider).snapshot(objectID: 10)
        XCTAssertEqual(snapshot.availableBufferFrameSizeRange, AudioBufferRange(minimum: 32, maximum: 1024))
    }

    func testUnavailablePropertyIsCapabilityGapNotFailure() async throws {
        let provider = MockHALProvider()
        provider.add(7, HALSelector.name, .string("Minimal"))
        let snapshot = try await AudioDeviceProfiler(provider: provider).snapshot(objectID: 7)
        XCTAssertNil(snapshot.deviceUID)
        XCTAssertEqual(snapshot.rawDiagnostics["deviceUID"], "unavailable; object ID used for this session")
    }

    func testProviderOSStatusIsRetained() {
        let provider = MockHALProvider(); let address = AudioPropertyAddressDescriptor(selector: HALSelector.name)
        provider.fail(address: address, status: -50)
        XCTAssertThrowsError(try provider.value(objectID: 1, address: address)) { error in
            guard case let AudioDevicePropertyError.osStatus(status, _, returnedAddress) = error else { return XCTFail("wrong error") }
            XCTAssertEqual(status, -50); XCTAssertEqual(returnedAddress, address)
        }
    }

    func testSnapshotDiffReportsLatencyAndClockChanges() async throws {
        let provider = MockHALProvider(); provider.add(1, HALSelector.name, .string("A")); provider.add(1, HALSelector.latency, .uint32(4))
        let profiler = AudioDeviceProfiler(provider: provider)
        let first = try await profiler.snapshot(objectID: 1)
        provider.add(1, HALSelector.latency, .uint32(12))
        let second = try await profiler.snapshot(objectID: 1)
        let diff = await profiler.compare(first, second)
        XCTAssertTrue(diff.changes.contains("latency"))
    }

    func testVirtualAndAggregateTransportClassification() async throws {
        let provider = MockHALProvider()
        provider.add(2, HALSelector.name, .string("Aggregate")); provider.add(2, HALSelector.transport, .uint32(0x67727570))
        provider.add(3, HALSelector.name, .string("Virtual")); provider.add(3, HALSelector.transport, .uint32(0x76697274))
        let profiler = AudioDeviceProfiler(provider: provider)
        let snapshots = try await profiler.snapshots()
        XCTAssertTrue(snapshots.first(where: { $0.objectID == 2 })?.isAggregateDevice == true)
        XCTAssertTrue(snapshots.first(where: { $0.objectID == 3 })?.isVirtualDevice == true)
    }

    func testSnapshotJSONAnonymizesIdentifiersByDefault() throws {
        let snapshot = AudioDeviceSnapshot(objectID: 9, name: "USB", deviceUID: "private.uid", modelUID: "private.model")
        let redacted = String(data: try snapshot.encodedJSON(), encoding: .utf8) ?? ""
        XCTAssertFalse(redacted.contains("private.uid")); XCTAssertFalse(redacted.contains("private.model"))
        let detailed = String(data: try snapshot.encodedJSON(includeDetailedIdentifiers: true), encoding: .utf8) ?? ""
        XCTAssertTrue(detailed.contains("private.uid"))
    }

    private func bufferList(channelCount: UInt32) -> Data {
        var data = Data(); let count: UInt32 = 1; let bytes: UInt32 = 0; let channels = channelCount; let pointer: UInt64 = 0
        for value in [count, bytes, channels] { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        withUnsafeBytes(of: pointer) { data.append(contentsOf: $0) }
        return data
    }

    private func doubleRange(minimum: Double, maximum: Double) -> Data {
        var data = Data(); for var value in [minimum, maximum] { withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }; return data
    }
}

private final class MockHALProvider: AudioPropertyProvider, @unchecked Sendable {
    private struct Key: Hashable { let objectID: UInt32; let address: AudioPropertyAddressDescriptor }
    private var values: [Key: AudioPropertyValue] = [:]
    private var failures: [Key: Int32] = [:]
    private var ids: Set<UInt32> = []
    func add(_ objectID: UInt32, _ selector: UInt32, _ value: AudioPropertyValue, scope: AudioPropertyScope = .global) { let key = Key(objectID: objectID, address: AudioPropertyAddressDescriptor(selector: selector, scope: scope)); values[key] = value; ids.insert(objectID) }
    func fail(address: AudioPropertyAddressDescriptor, status: Int32) { failures[Key(objectID: 1, address: address)] = status }
    func deviceIDs() throws -> [UInt32] { Array(ids) }
    func hasProperty(objectID: UInt32, address: AudioPropertyAddressDescriptor) -> Bool { values[Key(objectID: objectID, address: address)] != nil || failures[Key(objectID: objectID, address: address)] != nil }
    func value(objectID: UInt32, address: AudioPropertyAddressDescriptor) throws -> AudioPropertyValue {
        let key = Key(objectID: objectID, address: address)
        if let status = failures[key] { throw AudioDevicePropertyError.osStatus(status: status, operation: "mock read", address: address) }
        guard let value = values[key] else { throw AudioDevicePropertyError.unavailable(address: address) }
        return value
    }
    func registerListener(objectID: UInt32, address: AudioPropertyAddressDescriptor, handler: @escaping @Sendable () -> Void) throws {}
    func removeListener(objectID: UInt32, address: AudioPropertyAddressDescriptor) throws {}
}
