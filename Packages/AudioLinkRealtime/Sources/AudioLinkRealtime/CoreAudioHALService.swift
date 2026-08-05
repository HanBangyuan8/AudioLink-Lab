import AudioLinkCore
import Foundation

public enum AudioPropertyValue: Equatable, Sendable {
    case string(String)
    case double(Double)
    case uint32(UInt32)
    case int32(Int32)
    case bool(Bool)
    case bytes(Data)
}

/// Narrow boundary around AudioObjectGetPropertyData. Production code and
/// tests use this protocol instead of constructing Core Audio addresses.
public protocol AudioPropertyProvider: Sendable {
    func deviceIDs() throws -> [UInt32]
    func hasProperty(objectID: UInt32, address: AudioPropertyAddressDescriptor) -> Bool
    func value(objectID: UInt32, address: AudioPropertyAddressDescriptor) throws -> AudioPropertyValue
    func registerListener(objectID: UInt32, address: AudioPropertyAddressDescriptor, handler: @escaping @Sendable () -> Void) throws
    func removeListener(objectID: UInt32, address: AudioPropertyAddressDescriptor) throws
}

public actor AudioDeviceProfiler {
    private let provider: any AudioPropertyProvider
    private var listenerTask: Task<Void, Never>?
    private var continuation: AsyncStream<AudioDeviceChangeEvent>.Continuation?
    private var lastSnapshots: [String: AudioDeviceSnapshot] = [:]
    private var registeredListeners: [(UInt32, AudioPropertyAddressDescriptor)] = []
    private var currentDefaultInput: String?
    private var currentDefaultOutput: String?

    public init(provider: any AudioPropertyProvider = SystemCoreAudioPropertyProvider()) {
        self.provider = provider
    }

    deinit { listenerTask?.cancel() }

    public func snapshot(objectID: UInt32, capturedAt: Date = Date()) throws -> AudioDeviceSnapshot {
        try makeSnapshot(objectID: objectID, capturedAt: capturedAt)
    }

    public func snapshots(capturedAt: Date = Date()) throws -> [AudioDeviceSnapshot] {
        try provider.deviceIDs().map { objectID in
            do { return try makeSnapshot(objectID: objectID, capturedAt: capturedAt) }
            catch { return fallbackSnapshot(objectID: objectID, capturedAt: capturedAt, error: error) }
        }
    }

    public func compare(_ old: AudioDeviceSnapshot, _ new: AudioDeviceSnapshot) -> AudioDeviceSnapshotDiff {
        var changes: [String] = []
        if old.nominalSampleRate != new.nominalSampleRate { changes.append("nominalSampleRate") }
        if old.availableBufferFrameSizeRange != new.availableBufferFrameSizeRange { changes.append("bufferFrameSizeRange") }
        if old.bufferFrameSize != new.bufferFrameSize { changes.append("bufferFrameSize") }
        if old.streams != new.streams { changes.append("streams") }
        if old.channels != new.channels { changes.append("channels") }
        if old.latencyFrames != new.latencyFrames { changes.append("latency") }
        if old.clockSource != new.clockSource { changes.append("clockSource") }
        if old.isAlive != new.isAlive { changes.append("alive") }
        if old.isRunning != new.isRunning { changes.append("running") }
        if old.manufacturer != new.manufacturer { changes.append("manufacturer") }
        return AudioDeviceSnapshotDiff(identity: new.stableIdentity, changes: changes)
    }

    /// The stream intentionally performs only lightweight snapshot work. Core
    /// Audio listeners may fire in bursts; coalescing is done by comparing the
    /// latest snapshot, and the callback itself never performs a property read.
    public func events(pollInterval: Duration = .milliseconds(250)) -> AsyncStream<AudioDeviceChangeEvent> {
        stopEvents()
        let stream = AsyncStream<AudioDeviceChangeEvent> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stopEvents() }
            }
        }
        listenerTask = Task { [weak self] in
            guard let self else { return }
            await self.publishInitialSnapshots()
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollInterval) }
                catch { break }
                guard !Task.isCancelled else { break }
                await self.refreshAndPublish()
            }
            await self.finishEvents()
        }
        return stream
    }

    public func stopEvents() {
        listenerTask?.cancel(); listenerTask = nil
        for (objectID, address) in registeredListeners { try? provider.removeListener(objectID: objectID, address: address) }
        registeredListeners.removeAll()
        continuation?.finish(); continuation = nil
    }

    private func publishInitialSnapshots() {
        do {
            let current = try snapshots()
            lastSnapshots = Dictionary(uniqueKeysWithValues: current.map { ($0.stableIdentity, $0) })
            current.forEach { continuation?.yield(.added($0)) }
            registerListeners(for: current)
        } catch { continuation?.finish() }
    }

    private func registerListeners(for snapshots: [AudioDeviceSnapshot]) {
        let selectors = [HALSelector.nominalSampleRate, HALSelector.bufferFrameSize, HALSelector.streamConfiguration, HALSelector.alive, HALSelector.running]
        for snapshot in snapshots {
            for selector in selectors {
                let address = address(selector, scope: selector == HALSelector.streamConfiguration ? .input : .global)
                do {
                    try provider.registerListener(objectID: snapshot.objectID, address: address) { [weak self] in
                        Task { await self?.refreshAndPublish() }
                    }
                    registeredListeners.append((snapshot.objectID, address))
                } catch {
                    // Listener support is optional for providers. Polling remains
                    // active and the error is surfaced through the next snapshot.
                }
            }
        }
    }

    private func refreshAndPublish() {
        guard let current = try? snapshots() else { return }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.stableIdentity, $0) })
        for (identity, previous) in lastSnapshots where byID[identity] == nil {
            continuation?.yield(.removed(identity: identity, objectID: previous.objectID))
        }
        for snapshot in current {
            if let previous = lastSnapshots[snapshot.stableIdentity] {
                let diff = compare(previous, snapshot)
                if diff.hasChanges { continuation?.yield(.snapshotChanged(diff)) }
            } else { continuation?.yield(.added(snapshot)) }
        }
        lastSnapshots = byID
    }

    private func finishEvents() { continuation?.finish(); continuation = nil; listenerTask = nil }

    private func makeSnapshot(objectID: UInt32, capturedAt: Date) throws -> AudioDeviceSnapshot {
        let global = AudioPropertyScope.global
        let name = try string(objectID, selector: HALSelector.name, scope: global) ?? "Audio Device \(objectID)"
        let manufacturer = try string(objectID, selector: HALSelector.manufacturer, scope: global)
        let uid = try string(objectID, selector: HALSelector.deviceUID, scope: global)
        let modelUID = try string(objectID, selector: HALSelector.modelUID, scope: global)
        let transportValue = try uint32(objectID, selector: HALSelector.transport, scope: global)
        let transport = DeviceDescriptor.Transport(coreAudioTransport: transportValue)
        let inputChannels = try streamChannelCount(objectID: objectID, scope: .input)
        let outputChannels = try streamChannelCount(objectID: objectID, scope: .output)
        let nominalRate = try sampleRate(objectID, selector: HALSelector.nominalSampleRate, scope: global)
        let rates = try sampleRates(objectID, scope: global)
        let bufferSize = try int(objectID, selector: HALSelector.bufferFrameSize, scope: global)
        let bufferRange = try bufferRange(objectID: objectID, scope: global)
        let safetyOffset = try int(objectID, selector: HALSelector.safetyOffset, scope: global)
        let latency = try int(objectID, selector: HALSelector.latency, scope: global)
        let inputLatency = try int(objectID, selector: HALSelector.latency, scope: .input)
        let outputLatency = try int(objectID, selector: HALSelector.latency, scope: .output)
        let alive = try bool(objectID, selector: HALSelector.alive, scope: global)
        let running = try bool(objectID, selector: HALSelector.running, scope: global)
        let streams = try streamDescriptors(objectID: objectID, inputChannels: inputChannels, outputChannels: outputChannels)
        let inputVolume = provider.hasProperty(objectID: objectID, address: address(HALSelector.volumeScalar, scope: .input))
        let outputVolume = provider.hasProperty(objectID: objectID, address: address(HALSelector.volumeScalar, scope: .output))
        let inputMute = provider.hasProperty(objectID: objectID, address: address(HALSelector.mute, scope: .input))
        let outputMute = provider.hasProperty(objectID: objectID, address: address(HALSelector.mute, scope: .output))
        let hogOwner = try int32(objectID, selector: HALSelector.hogMode, scope: global)
        var diagnostics: [String: String] = [:]
        if uid == nil { diagnostics["deviceUID"] = "unavailable; object ID used for this session" }
        let isAggregate = transport == .aggregate
        let isVirtual = transport == .virtual
        let capabilities = [
            AudioDeviceCapability(key: "input", advertised: inputChannels > 0),
            AudioDeviceCapability(key: "output", advertised: outputChannels > 0),
            AudioDeviceCapability(key: "nominalSampleRate", advertised: nominalRate != nil),
            AudioDeviceCapability(key: "bufferFrameSizeRange", advertised: bufferRange != nil),
            AudioDeviceCapability(key: "inputVolume", advertised: inputVolume),
            AudioDeviceCapability(key: "outputVolume", advertised: outputVolume),
            AudioDeviceCapability(key: "inputMute", advertised: inputMute),
            AudioDeviceCapability(key: "outputMute", advertised: outputMute),
            AudioDeviceCapability(key: "dataSource", advertised: provider.hasProperty(objectID: objectID, address: address(HALSelector.dataSource, scope: .input))),
            AudioDeviceCapability(key: "clockSource", advertised: provider.hasProperty(objectID: objectID, address: address(HALSelector.clockSource, scope: .global)))
        ]
        return AudioDeviceSnapshot(
            objectID: objectID, capturedAt: capturedAt, name: name, manufacturer: manufacturer,
            deviceUID: uid, modelUID: modelUID, transport: transport,
            clock: AudioClockDescriptor(domain: try uint32(objectID, selector: HALSelector.clockDomain, scope: global)),
            isAlive: alive, isRunning: running, inputChannelCount: inputChannels, outputChannelCount: outputChannels,
            nominalSampleRate: nominalRate, availableNominalSampleRates: rates, bufferFrameSize: bufferSize,
            availableBufferFrameSizeRange: bufferRange, safetyOffsetFrames: safetyOffset, latencyFrames: latency,
            inputLatencyFrames: inputLatency, outputLatencyFrames: outputLatency, streams: streams,
            channels: streams.flatMap(\.channels), hogModeOwner: hogOwner, isAggregateDevice: isAggregate, isVirtualDevice: isVirtual,
            inputVolumeAvailable: inputVolume, outputVolumeAvailable: outputVolume,
            inputMuteAvailable: inputMute, outputMuteAvailable: outputMute,
            capabilities: capabilities, rawDiagnostics: diagnostics
        )
    }

    private func fallbackSnapshot(objectID: UInt32, capturedAt: Date, error: Error) -> AudioDeviceSnapshot {
        let propertyError = error as? AudioDevicePropertyError
        return AudioDeviceSnapshot(objectID: objectID, capturedAt: capturedAt, name: "Audio Device \(objectID)", rawDiagnostics: ["snapshotError": String(describing: error)], propertyErrors: propertyError.map { [$0] } ?? [])
    }

    private func address(_ selector: UInt32, scope: AudioPropertyScope, objectKind: AudioPropertyObjectKind = .device) -> AudioPropertyAddressDescriptor {
        AudioPropertyAddressDescriptor(selector: selector, scope: scope, objectKind: objectKind)
    }

    private func optionalValue(_ objectID: UInt32, selector: UInt32, scope: AudioPropertyScope) throws -> AudioPropertyValue? {
        let property = address(selector, scope: scope)
        guard provider.hasProperty(objectID: objectID, address: property) else { return nil }
        return try provider.value(objectID: objectID, address: property)
    }

    private func string(_ objectID: UInt32, selector: UInt32, scope: AudioPropertyScope) throws -> String? {
        guard let value = try optionalValue(objectID, selector: selector, scope: scope) else { return nil }
        if case let .string(value) = value { return value }
        throw AudioDevicePropertyError.invalidValue(operation: "read string", address: address(selector, scope: scope), detail: "not a string")
    }

    private func double(_ objectID: UInt32, selector: UInt32, scope: AudioPropertyScope) throws -> Double? {
        guard let value = try optionalValue(objectID, selector: selector, scope: scope) else { return nil }
        switch value { case let .double(value): return value; case let .uint32(value): return Double(value); default: throw AudioDevicePropertyError.invalidValue(operation: "read numeric value", address: address(selector, scope: scope), detail: "not numeric") }
    }

    private func uint32(_ objectID: UInt32, selector: UInt32, scope: AudioPropertyScope) throws -> UInt32? {
        guard let value = try optionalValue(objectID, selector: selector, scope: scope) else { return nil }
        switch value { case let .uint32(value): return value; case let .int32(value) where value >= 0: return UInt32(value); default: throw AudioDevicePropertyError.invalidValue(operation: "read UInt32", address: address(selector, scope: scope), detail: "not an unsigned integer") }
    }

    private func bool(_ objectID: UInt32, selector: UInt32, scope: AudioPropertyScope) throws -> Bool? {
        guard let value = try optionalValue(objectID, selector: selector, scope: scope) else { return nil }
        if case let .bool(value) = value { return value }
        if case let .uint32(value) = value { return value != 0 }
        throw AudioDevicePropertyError.invalidValue(operation: "read boolean", address: address(selector, scope: scope), detail: "not boolean")
    }

    private func int(_ objectID: UInt32, selector: UInt32, scope: AudioPropertyScope) throws -> Int? {
        guard let value = try optionalValue(objectID, selector: selector, scope: scope) else { return nil }
        switch value { case let .uint32(value): return Int(value); case let .int32(value) where value >= 0: return Int(value); default: return nil }
    }

    private func int32(_ objectID: UInt32, selector: UInt32, scope: AudioPropertyScope) throws -> Int32? {
        guard let value = try optionalValue(objectID, selector: selector, scope: scope) else { return nil }
        if case let .int32(value) = value { return value }
        if case let .uint32(value) = value { return Int32(bitPattern: value) }
        return nil
    }

    private func sampleRate(_ objectID: UInt32, selector: UInt32, scope: AudioPropertyScope) throws -> SampleRate? {
        guard let value = try double(objectID, selector: selector, scope: scope), value.isFinite, value > 0 else { return nil }
        return try SampleRate(hertz: value)
    }

    private func sampleRates(_ objectID: UInt32, scope: AudioPropertyScope) throws -> [SampleRate] {
        guard let value = try optionalValue(objectID, selector: HALSelector.availableNominalSampleRates, scope: scope) else { return [] }
        guard case let .bytes(data) = value else { return [] }
        // Core Audio stores AudioValueRange pairs. Keep only finite, positive
        // ranges; do not invent every integer sample rate between them.
        let pairStride = MemoryLayout<Double>.size * 2
        guard data.count >= pairStride else { return [] }
        var result: [SampleRate] = []
        for offset in Swift.stride(from: 0, to: data.count - pairStride + 1, by: pairStride) {
            let minimum = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Double.self) }
            let maximum = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 8, as: Double.self) }
            for candidate in [minimum, maximum] where candidate.isFinite && candidate > 0 {
                if let rate = try? SampleRate(hertz: candidate), !result.contains(rate) { result.append(rate) }
            }
        }
        return result.sorted()
    }

    private func bufferRange(objectID: UInt32, scope: AudioPropertyScope) throws -> AudioBufferRange? {
        guard let value = try optionalValue(objectID, selector: HALSelector.bufferFrameSizeRange, scope: scope) else { return nil }
        guard case let .bytes(data) = value, data.count >= 8 else { return nil }
        let minimum: Int
        let maximum: Int
        if data.count >= 16 {
            let minValue = data.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
            let maxValue = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Double.self) }
            guard minValue.isFinite, maxValue.isFinite else { return nil }
            minimum = Int(minValue.rounded()); maximum = Int(maxValue.rounded())
        } else {
            minimum = data.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
            maximum = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        }
        guard minimum > 0, maximum >= minimum else { return nil }
        return AudioBufferRange(minimum: minimum, maximum: maximum)
    }

    private func streamChannelCount(objectID: UInt32, scope: AudioPropertyScope) throws -> Int {
        guard let value = try optionalValue(objectID, selector: HALSelector.streamConfiguration, scope: scope), case let .bytes(data) = value else { return 0 }
        return parseAudioBufferListChannelCount(data)
    }

    private func parseAudioBufferListChannelCount(_ data: Data) -> Int {
        guard data.count >= 4 else { return 0 }
        let bufferCount = data.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
        let stride = 8 + MemoryLayout<UInt32>.size * 2
        guard bufferCount >= 0, bufferCount <= 128, data.count >= 4 + bufferCount * stride else { return 0 }
        return (0..<bufferCount).reduce(0) { total, index in
            total + Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 + index * stride + 4, as: UInt32.self) })
        }
    }

    private func streamDescriptors(objectID: UInt32, inputChannels: Int, outputChannels: Int) throws -> [AudioStreamDescriptor] {
        var streams: [AudioStreamDescriptor] = []
        if inputChannels > 0 { streams.append(AudioStreamDescriptor(objectID: objectID, scope: .input, channels: (0..<inputChannels).map { AudioChannelDescriptor(index: $0, scope: .input) })) }
        if outputChannels > 0 { streams.append(AudioStreamDescriptor(objectID: objectID, scope: .output, channels: (0..<outputChannels).map { AudioChannelDescriptor(index: $0, scope: .output) })) }
        return streams
    }
}

/// Name used by integration code that wants to treat the profiler as the HAL
/// service boundary. It intentionally aliases the actor so there is one
/// concurrency owner rather than two competing device caches.
public typealias CoreAudioHALService = AudioDeviceProfiler

public enum HALSelector {
    public static let name: UInt32 = 0x6C6E616D // 'lnam'
    public static let manufacturer: UInt32 = 0x6C6D616B // 'lmak'
    public static let deviceUID: UInt32 = 0x75696420 // 'uid '
    public static let modelUID: UInt32 = 0x6D756964 // 'muid'
    public static let transport: UInt32 = 0x7472616E // 'tran'
    public static let clockDomain: UInt32 = 0x636C6B64 // 'clkd'
    public static let alive: UInt32 = 0x6C69766E // 'livn'
    public static let running: UInt32 = 0x676F696E // 'goin'
    public static let nominalSampleRate: UInt32 = 0x6E737274
    public static let availableNominalSampleRates: UInt32 = 0x6E737223 // 'nsr#'
    public static let bufferFrameSize: UInt32 = 0x6673697A // 'fsiz'
    public static let bufferFrameSizeRange: UInt32 = 0x66737A23 // 'fsz#'
    public static let safetyOffset: UInt32 = 0x73616674 // 'saft'
    public static let latency: UInt32 = 0x6C746E63
    public static let streamConfiguration: UInt32 = 0x736C6179 // 'slay'
    public static let hogMode: UInt32 = 0x6F696E6B // 'oink'
    public static let volumeScalar: UInt32 = 0x766F6C6D // 'volm'
    public static let mute: UInt32 = 0x6D757465 // 'mute'
    public static let dataSource: UInt32 = 0x73737263 // 'ssrc'
    public static let clockSource: UInt32 = 0x63737263 // 'csrc'
}

private extension DeviceDescriptor.Transport {
    init(coreAudioTransport: UInt32?) {
        switch coreAudioTransport {
        case 0x626C746E: self = .builtIn // 'bltn'
        case 0x75736220: self = .usb // 'usb '
        case 0x626C7565, 0x626C6561: self = .bluetooth // 'blue', 'blea'
        case 0x67727570: self = .aggregate // 'grup'
        case 0x76697274: self = .virtual
        default: self = .unknown
        }
    }
}

#if os(macOS)
import CoreAudio

public final class SystemCoreAudioPropertyProvider: AudioPropertyProvider, @unchecked Sendable {
    private let listenerLock = NSLock()
    private var listeners: [String: AudioObjectPropertyListenerBlock] = [:]
    public init() {}
    deinit {
        listenerLock.lock(); let current = listeners; listeners.removeAll(); listenerLock.unlock()
        for keyAndBlock in current {
            let parts = keyAndBlock.key.split(separator: ":")
            guard parts.count == 4, let objectID = UInt32(parts[0]), let selector = UInt32(parts[1]), let element = UInt32(parts[3]) else { continue }
            let scope: AudioPropertyScope = parts[2] == "input" ? .input : parts[2] == "output" ? .output : .global
            var address = nativeAddress(AudioPropertyAddressDescriptor(selector: selector, scope: scope, element: element))
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(objectID), &address, nil, keyAndBlock.value)
        }
    }

    public func deviceIDs() throws -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount)
        guard status == noErr else { throw error(status, "read device list size", address) }
        guard byteCount % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { throw AudioDevicePropertyError.malformedData(operation: "read device list", expectedBytes: MemoryLayout<AudioObjectID>.size, actualBytes: Int(byteCount), address: descriptor(address)) }
        var values = [AudioObjectID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        let result = values.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(paramErr) }
            var size = byteCount
            return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, baseAddress)
        }
        guard result == noErr else { throw error(result, "read device list", address) }
        return values.map { UInt32($0) }
    }

    public func hasProperty(objectID: UInt32, address descriptor: AudioPropertyAddressDescriptor) -> Bool {
        var address = nativeAddress(descriptor)
        return AudioObjectHasProperty(AudioObjectID(objectID), &address)
    }

    public func value(objectID: UInt32, address descriptor: AudioPropertyAddressDescriptor) throws -> AudioPropertyValue {
        guard hasProperty(objectID: objectID, address: descriptor) else { throw AudioDevicePropertyError.unavailable(address: descriptor) }
        var address = nativeAddress(descriptor)
        var byteCount: UInt32 = 0
        let id = AudioObjectID(objectID)
        let sizeStatus = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &byteCount)
        guard sizeStatus == noErr else { throw error(sizeStatus, "read property size", address) }
        let selector = descriptor.selector
        if selector == kAudioObjectPropertyName || selector == kAudioObjectPropertyManufacturer || selector == kAudioDevicePropertyDeviceUID || selector == kAudioDevicePropertyModelUID {
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
            guard status == noErr else { throw error(status, "read string property", address) }
            guard let value else { throw AudioDevicePropertyError.malformedData(operation: "read string property", expectedBytes: Int(size), actualBytes: 0, address: descriptor) }
            return .string(value.takeUnretainedValue() as String)
        }
        var data = Data(count: Int(byteCount))
        let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(paramErr) }
            var size = byteCount
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, baseAddress)
        }
        guard status == noErr else { throw error(status, "read property", address) }
        switch byteCount {
        case UInt32(MemoryLayout<Float64>.size) where selector == kAudioDevicePropertyNominalSampleRate:
            return .double(data.withUnsafeBytes { $0.loadUnaligned(as: Float64.self) })
        case UInt32(MemoryLayout<UInt32>.size):
            return .uint32(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        default: return .bytes(data)
        }
    }

    public func registerListener(objectID: UInt32, address descriptor: AudioPropertyAddressDescriptor, handler: @escaping @Sendable () -> Void) throws {
        // Listener registration is intentionally owned by this provider. The
        // callback does no reads and schedules work on the profiler actor.
        try removeListener(objectID: objectID, address: descriptor)
        var address = nativeAddress(descriptor)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(objectID), &address, nil, block)
        guard status == noErr else { throw error(status, "register property listener", address) }
        let key = "\(objectID):\(descriptor.selector):\(descriptor.scope.rawValue):\(descriptor.element)"
        listenerLock.lock(); listeners[key] = block; listenerLock.unlock()
    }

    public func removeListener(objectID: UInt32, address descriptor: AudioPropertyAddressDescriptor) throws {
        let key = "\(objectID):\(descriptor.selector):\(descriptor.scope.rawValue):\(descriptor.element)"
        listenerLock.lock(); let block = listeners.removeValue(forKey: key); listenerLock.unlock()
        guard let block else { return }
        var address = nativeAddress(descriptor)
        let status = AudioObjectRemovePropertyListenerBlock(AudioObjectID(objectID), &address, nil, block)
        guard status == noErr else { throw error(status, "remove property listener", address) }
    }

    private func nativeAddress(_ descriptor: AudioPropertyAddressDescriptor) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: descriptor.selector, mScope: descriptor.scope.native, mElement: descriptor.element)
    }

    private func descriptor(_ address: AudioObjectPropertyAddress) -> AudioPropertyAddressDescriptor {
        AudioPropertyAddressDescriptor(selector: address.mSelector, scope: address.mScope == kAudioObjectPropertyScopeInput ? .input : address.mScope == kAudioObjectPropertyScopeOutput ? .output : .global, element: address.mElement)
    }

    private func error(_ status: OSStatus, _ operation: String, _ address: AudioObjectPropertyAddress) -> AudioDevicePropertyError {
        .osStatus(status: status, operation: operation, address: descriptor(address))
    }
}

private extension AudioPropertyScope {
    var native: AudioObjectPropertyScope { switch self { case .global: kAudioObjectPropertyScopeGlobal; case .input: kAudioObjectPropertyScopeInput; case .output: kAudioObjectPropertyScopeOutput } }
}
#else

public struct SystemCoreAudioPropertyProvider: AudioPropertyProvider {
    public init() {}
    public func deviceIDs() throws -> [UInt32] { [] }
    public func hasProperty(objectID: UInt32, address: AudioPropertyAddressDescriptor) -> Bool { false }
    public func value(objectID: UInt32, address: AudioPropertyAddressDescriptor) throws -> AudioPropertyValue { throw AudioDevicePropertyError.unavailable(address: address) }
    public func registerListener(objectID: UInt32, address: AudioPropertyAddressDescriptor, handler: @escaping @Sendable () -> Void) throws { throw AudioDevicePropertyError.unavailable(address: address) }
    public func removeListener(objectID: UInt32, address: AudioPropertyAddressDescriptor) throws {}
}

#endif
