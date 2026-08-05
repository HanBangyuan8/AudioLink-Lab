import AudioLinkCore
import AudioToolbox
import Foundation

#if os(macOS)
import CoreAudio

public final class SystemAudioDeviceService: AudioDeviceService, Sendable {
    public init() {}

    public func devices() async throws -> [AudioDeviceDescription] {
        let defaultInputID = try defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutputID = try defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        return try allDeviceIDs().compactMap { deviceID in
            try describe(
                deviceID: deviceID,
                defaultInputID: defaultInputID,
                defaultOutputID: defaultOutputID
            )
        }
        .sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func defaultInputDevice() async throws -> AudioDeviceDescription? {
        let target = try defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
        return try await devices().first { $0.objectID == target }
    }

    public func defaultOutputDevice() async throws -> AudioDeviceDescription? {
        let target = try defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        return try await devices().first { $0.objectID == target }
    }

    public func validate(route: AudioRouteConfiguration) async throws {
        let current = try await devices()
        guard let input = current.first(where: { $0.id == route.inputDevice.id }), input.inputChannelCount > 0 else {
            throw RealtimeMeasurementFailure(
                code: .inputDeviceUnavailable,
                userMessage: "The selected input device is no longer available.",
                recoverySuggestion: "Refresh devices and select an input again.",
                technicalContext: route.inputDevice.id
            )
        }
        guard let output = current.first(where: { $0.id == route.outputDevice.id }), output.outputChannelCount > 0 else {
            throw RealtimeMeasurementFailure(
                code: .outputDeviceUnavailable,
                userMessage: "The selected output device is no longer available.",
                recoverySuggestion: "Refresh devices and select an output again.",
                technicalContext: route.outputDevice.id
            )
        }
        guard (0..<input.inputChannelCount).contains(route.inputChannel) else {
            throw invalidChannel(kind: "input", requested: route.inputChannel, available: input.inputChannelCount)
        }
        guard (0..<output.outputChannelCount).contains(route.outputChannel) else {
            throw invalidChannel(kind: "output", requested: route.outputChannel, available: output.outputChannelCount)
        }
        let inputMatches = abs(input.nominalSampleRate.hertz - route.sampleRate.hertz) < 0.5
        let outputMatches = abs(output.nominalSampleRate.hertz - route.sampleRate.hertz) < 0.5
        guard inputMatches, outputMatches else {
            throw RealtimeMeasurementFailure(
                code: .sampleRateMismatch,
                userMessage: "The selected input and output are not running at the same sample rate.",
                recoverySuggestion: "Choose compatible devices or set both devices to (Int(route.sampleRate.hertz)) Hz in Audio MIDI Setup.",
                technicalContext: "input=\(input.nominalSampleRate.hertz), output=\(output.nominalSampleRate.hertz), requested=\(route.sampleRate.hertz)"
            )
        }
        guard (32...8_192).contains(route.bufferFrameCount) else {
            throw RealtimeMeasurementFailure(
                code: .incompatibleRoute,
                userMessage: "The requested audio buffer size is not supported by AudioLink Lab.",
                recoverySuggestion: "Choose a buffer size from 32 through 8192 frames.",
                technicalContext: "bufferFrameCount=\(route.bufferFrameCount)"
            )
        }
    }

    public func events() -> AsyncStream<AudioDeviceEvent> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var previous: Snapshot
                do {
                    previous = try await self.snapshot()
                } catch {
                    // A device-list error is not a harmless empty update. End
                    // monitoring so the caller can surface/retry it explicitly.
                    continuation.finish()
                    return
                }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        break
                    }
                    guard !Task.isCancelled else { break }
                    let current: Snapshot
                    do {
                        current = try await self.snapshot()
                    } catch {
                        continuation.finish()
                        return
                    }
                    Self.emitDifferences(previous: previous, current: current, to: continuation)
                    previous = current
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Snapshot: Sendable {
        let devices: [AudioDeviceDescription]
        let defaultInputUID: String?
        let defaultOutputUID: String?
    }

    private func snapshot() async throws -> Snapshot {
        let all = try await devices()
        return Snapshot(
            devices: all,
            defaultInputUID: all.first(where: \.isDefaultInput)?.id,
            defaultOutputUID: all.first(where: \.isDefaultOutput)?.id
        )
    }

    private static func emitDifferences(
        previous: Snapshot,
        current: Snapshot,
        to continuation: AsyncStream<AudioDeviceEvent>.Continuation
    ) {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.devices.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.devices.map { ($0.id, $0) })
        if Set(previousByID.keys) != Set(currentByID.keys) {
            continuation.yield(.deviceListChanged)
        }
        for (uid, oldDevice) in previousByID where currentByID[uid] == nil {
            _ = oldDevice
            continuation.yield(.disconnected(uid: uid))
        }
        for (uid, newDevice) in currentByID {
            guard let oldDevice = previousByID[uid],
                  oldDevice.nominalSampleRate != newDevice.nominalSampleRate else { continue }
            continuation.yield(
                .nominalSampleRateChanged(
                    uid: uid,
                    oldValue: oldDevice.nominalSampleRate,
                    newValue: newDevice.nominalSampleRate
                )
            )
        }
        if previous.defaultInputUID != current.defaultInputUID {
            continuation.yield(.defaultInputChanged(uid: current.defaultInputUID))
        }
        if previous.defaultOutputUID != current.defaultOutputUID {
            continuation.yield(.defaultOutputChanged(uid: current.defaultOutputUID))
        }
    }

    private func invalidChannel(kind: String, requested: Int, available: Int) -> RealtimeMeasurementFailure {
        RealtimeMeasurementFailure(
            code: .invalidChannel,
            userMessage: "The selected \(kind) channel is unavailable.",
            recoverySuggestion: "Choose a channel from the refreshed device capabilities.",
            technicalContext: "requested=\(requested), available=\(available)"
        )
    }

    private func allDeviceIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
            operation: "read audio device list size"
        )
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: count)
        try values.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var mutableSize = size
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &mutableSize,
                    baseAddress
                ),
                operation: "read audio device list"
            )
        }
        return values
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) throws -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &value
            ),
            operation: "read default audio device"
        )
        return value == kAudioObjectUnknown ? nil : value
    }

    private func describe(
        deviceID: AudioObjectID,
        defaultInputID: AudioObjectID?,
        defaultOutputID: AudioObjectID?
    ) throws -> AudioDeviceDescription? {
        let inputChannels = try channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputChannels = try channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
        guard inputChannels > 0 || outputChannels > 0 else { return nil }
        let uid = try stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
        let name = try stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName)
        let manufacturer = try? stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyManufacturer)
        let rate = try numericProperty(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate)
        let transportValue = try? uint32Property(deviceID: deviceID, selector: kAudioDevicePropertyTransportType)
        return AudioDeviceDescription(
            descriptor: DeviceDescriptor(
                id: uid,
                name: name,
                manufacturer: manufacturer,
                transport: transport(from: transportValue),
                supportsInput: inputChannels > 0,
                supportsOutput: outputChannels > 0
            ),
            objectID: deviceID,
            nominalSampleRate: try SampleRate(hertz: rate),
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels,
            isDefaultInput: deviceID == defaultInputID,
            isDefaultOutput: deviceID == defaultOutputID
        )
    }

    private func channelCount(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            operation: "read stream configuration size"
        )
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage),
            operation: "read stream configuration"
        )
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { partial, buffer in
            partial + Int(buffer.mNumberChannels)
        }
    }

    private func stringProperty(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value),
            operation: "read audio device string property"
        )
        guard let string = value?.takeUnretainedValue() else {
            throw RealtimeMeasurementFailure(
                code: .incompatibleRoute,
                userMessage: "Core Audio returned an incomplete device description.",
                recoverySuggestion: "Reconnect the device and refresh the list.",
                technicalContext: "Missing CFString for selector \(selector)"
            )
        }
        return string as String
    }

    private func numericProperty(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value),
            operation: "read audio device numeric property"
        )
        return value
    }

    private func uint32Property(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value),
            operation: "read audio device integer property"
        )
        return value
    }

    private func transport(from value: UInt32?) -> DeviceDescriptor.Transport {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeAggregate: .aggregate
        case kAudioDeviceTransportTypeVirtual: .virtual
        default: .unknown
        }
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw RealtimeMeasurementFailure(
                code: .incompatibleRoute,
                userMessage: "AudioLink Lab could not inspect the current Core Audio route.",
                recoverySuggestion: "Reconnect the device, then refresh the device list.",
                technicalContext: "\(operation): OSStatus \(status)"
            )
        }
    }
}

#else

public struct SystemAudioDeviceService: AudioDeviceService {
    public init() {}
    public func devices() async throws -> [AudioDeviceDescription] { [] }
    public func defaultInputDevice() async throws -> AudioDeviceDescription? { nil }
    public func defaultOutputDevice() async throws -> AudioDeviceDescription? { nil }
    public func validate(route: AudioRouteConfiguration) async throws {
        throw RealtimeMeasurementFailure(
            code: .incompatibleRoute,
            userMessage: "Explicit audio device routing is not available on this platform yet.",
            recoverySuggestion: "Use the system audio route.",
            technicalContext: nil
        )
    }
    public func events() -> AsyncStream<AudioDeviceEvent> { AsyncStream { $0.finish() } }
}

#endif
