import AudioLinkCore
import Foundation

/// The scope used when querying a Core Audio property. Keeping this explicit
/// prevents an input value from accidentally being presented as an output
/// capability.
public enum AudioPropertyScope: String, Codable, CaseIterable, Sendable {
    case global
    case input
    case output
}

public enum AudioPropertyObjectKind: String, Codable, CaseIterable, Sendable {
    case system
    case device
    case stream
    case control
}

public struct AudioPropertyAddressDescriptor: Codable, Equatable, Hashable, Sendable {
    public let selector: UInt32
    public let scope: AudioPropertyScope
    public let element: UInt32
    public let objectKind: AudioPropertyObjectKind

    public init(
        selector: UInt32,
        scope: AudioPropertyScope = .global,
        element: UInt32 = 0,
        objectKind: AudioPropertyObjectKind = .device
    ) {
        self.selector = selector
        self.scope = scope
        self.element = element
        self.objectKind = objectKind
    }
}

public enum AudioDevicePropertyError: Error, Codable, Equatable, Sendable {
    case unavailable(address: AudioPropertyAddressDescriptor)
    case osStatus(
        status: Int32,
        operation: String,
        address: AudioPropertyAddressDescriptor
    )
    case malformedData(
        operation: String,
        expectedBytes: Int,
        actualBytes: Int,
        address: AudioPropertyAddressDescriptor
    )
    case invalidValue(operation: String, address: AudioPropertyAddressDescriptor, detail: String)
}

extension AudioDevicePropertyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This audio device does not advertise the requested capability."
        case let .osStatus(status, operation, address):
            return "Core Audio failed to \(operation) (OSStatus \(status), selector \(address.selector))."
        case let .malformedData(operation, expected, actual, _):
            return "Core Audio returned malformed data while trying to \(operation) (expected \(expected) bytes, received \(actual))."
        case let .invalidValue(operation, _, detail):
            return "Core Audio returned an invalid value while trying to \(operation): \(detail)."
        }
    }
}

public struct AudioBufferRange: Codable, Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int
    public let preferred: Int?

    public init(minimum: Int, maximum: Int, preferred: Int? = nil) {
        self.minimum = minimum
        self.maximum = max(minimum, maximum)
        self.preferred = preferred
    }

    public func contains(_ frameCount: Int) -> Bool {
        frameCount >= minimum && frameCount <= maximum
    }
}

public struct AudioChannelDescriptor: Codable, Equatable, Hashable, Sendable {
    public let index: Int
    public let scope: AudioPropertyScope
    public let label: String?
    public let name: String?
    public let group: Int?

    public init(index: Int, scope: AudioPropertyScope, label: String? = nil, name: String? = nil, group: Int? = nil) {
        self.index = index
        self.scope = scope
        self.label = label
        self.name = name
        self.group = group
    }
}

public struct AudioStreamFormatDescriptor: Codable, Equatable, Hashable, Sendable {
    public let sampleRate: SampleRate?
    public let channelCount: Int
    public let bitDepth: Int?
    public let isInterleaved: Bool?
    public let formatID: UInt32?

    public init(sampleRate: SampleRate?, channelCount: Int, bitDepth: Int? = nil, isInterleaved: Bool? = nil, formatID: UInt32? = nil) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.isInterleaved = isInterleaved
        self.formatID = formatID
    }
}

public struct AudioStreamDescriptor: Codable, Equatable, Hashable, Sendable {
    public let objectID: UInt32
    public let scope: AudioPropertyScope
    public let currentFormat: AudioStreamFormatDescriptor?
    public let availableFormats: [AudioStreamFormatDescriptor]
    public let latencyFrames: Int?
    public let channels: [AudioChannelDescriptor]

    public init(objectID: UInt32, scope: AudioPropertyScope, currentFormat: AudioStreamFormatDescriptor? = nil, availableFormats: [AudioStreamFormatDescriptor] = [], latencyFrames: Int? = nil, channels: [AudioChannelDescriptor] = []) {
        self.objectID = objectID
        self.scope = scope
        self.currentFormat = currentFormat
        self.availableFormats = availableFormats
        self.latencyFrames = latencyFrames
        self.channels = channels
    }
}

public struct AudioClockDescriptor: Codable, Equatable, Sendable {
    public let domain: UInt32?
    public let source: String?
    public let driftCompensationEnabled: Bool?
    public let supportsIndependentInputOutputClock: Bool?

    public init(domain: UInt32? = nil, source: String? = nil, driftCompensationEnabled: Bool? = nil, supportsIndependentInputOutputClock: Bool? = nil) {
        self.domain = domain
        self.source = source
        self.driftCompensationEnabled = driftCompensationEnabled
        self.supportsIndependentInputOutputClock = supportsIndependentInputOutputClock
    }
}

public struct AudioDeviceCapability: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let advertised: Bool
    public let verified: Bool?
    public let details: String?

    public init(key: String, advertised: Bool, verified: Bool? = nil, details: String? = nil) {
        self.key = key
        self.advertised = advertised
        self.verified = verified
        self.details = details
    }
}

public struct AudioDeviceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let objectID: UInt32
    public let capturedAt: Date
    public let name: String
    public let manufacturer: String?
    public let deviceUID: String?
    public let modelUID: String?
    public let transport: DeviceDescriptor.Transport
    public let clock: AudioClockDescriptor
    public let isAlive: Bool?
    public let isRunning: Bool?
    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let nominalSampleRate: SampleRate?
    public let availableNominalSampleRates: [SampleRate]
    public let bufferFrameSize: Int?
    public let availableBufferFrameSizeRange: AudioBufferRange?
    public let safetyOffsetFrames: Int?
    public let latencyFrames: Int?
    public let inputLatencyFrames: Int?
    public let outputLatencyFrames: Int?
    public let streams: [AudioStreamDescriptor]
    public let channels: [AudioChannelDescriptor]
    public let hogModeOwner: Int32?
    public let isAggregateDevice: Bool
    public let isVirtualDevice: Bool
    public let inputVolumeAvailable: Bool?
    public let outputVolumeAvailable: Bool?
    public let inputMuteAvailable: Bool?
    public let outputMuteAvailable: Bool?
    public let dataSource: String?
    public let clockSource: String?
    public let capabilities: [AudioDeviceCapability]
    public let rawDiagnostics: [String: String]
    public let propertyErrors: [AudioDevicePropertyError]

    public init(
        id: UUID = UUID(), objectID: UInt32, capturedAt: Date = Date(), name: String,
        manufacturer: String? = nil, deviceUID: String? = nil, modelUID: String? = nil,
        transport: DeviceDescriptor.Transport = .unknown, clock: AudioClockDescriptor = .init(),
        isAlive: Bool? = nil, isRunning: Bool? = nil, inputChannelCount: Int = 0,
        outputChannelCount: Int = 0, nominalSampleRate: SampleRate? = nil,
        availableNominalSampleRates: [SampleRate] = [], bufferFrameSize: Int? = nil,
        availableBufferFrameSizeRange: AudioBufferRange? = nil, safetyOffsetFrames: Int? = nil,
        latencyFrames: Int? = nil, inputLatencyFrames: Int? = nil, outputLatencyFrames: Int? = nil,
        streams: [AudioStreamDescriptor] = [], channels: [AudioChannelDescriptor] = [],
        hogModeOwner: Int32? = nil, isAggregateDevice: Bool = false, isVirtualDevice: Bool = false,
        inputVolumeAvailable: Bool? = nil, outputVolumeAvailable: Bool? = nil,
        inputMuteAvailable: Bool? = nil, outputMuteAvailable: Bool? = nil,
        dataSource: String? = nil, clockSource: String? = nil,
        capabilities: [AudioDeviceCapability] = [], rawDiagnostics: [String: String] = [:], propertyErrors: [AudioDevicePropertyError] = []
    ) {
        self.id = id; self.objectID = objectID; self.capturedAt = capturedAt; self.name = name
        self.manufacturer = manufacturer; self.deviceUID = deviceUID; self.modelUID = modelUID
        self.transport = transport; self.clock = clock; self.isAlive = isAlive; self.isRunning = isRunning
        self.inputChannelCount = inputChannelCount; self.outputChannelCount = outputChannelCount
        self.nominalSampleRate = nominalSampleRate; self.availableNominalSampleRates = availableNominalSampleRates
        self.bufferFrameSize = bufferFrameSize; self.availableBufferFrameSizeRange = availableBufferFrameSizeRange
        self.safetyOffsetFrames = safetyOffsetFrames; self.latencyFrames = latencyFrames
        self.inputLatencyFrames = inputLatencyFrames; self.outputLatencyFrames = outputLatencyFrames
        self.streams = streams; self.channels = channels; self.hogModeOwner = hogModeOwner
        self.isAggregateDevice = isAggregateDevice; self.isVirtualDevice = isVirtualDevice
        self.inputVolumeAvailable = inputVolumeAvailable; self.outputVolumeAvailable = outputVolumeAvailable
        self.inputMuteAvailable = inputMuteAvailable; self.outputMuteAvailable = outputMuteAvailable
        self.dataSource = dataSource; self.clockSource = clockSource; self.capabilities = capabilities
        self.rawDiagnostics = rawDiagnostics; self.propertyErrors = propertyErrors
    }

    public var stableIdentity: String { deviceUID ?? modelUID ?? "object-\(objectID)" }

    public func encodedJSON(includeDetailedIdentifiers: Bool = false) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard !includeDetailedIdentifiers,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        object.removeValue(forKey: "deviceUID")
        object.removeValue(forKey: "modelUID")
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

public struct AudioDeviceSnapshotDiff: Codable, Equatable, Sendable {
    public let identity: String
    public let changes: [String]

    public init(identity: String, changes: [String]) { self.identity = identity; self.changes = changes }
    public var hasChanges: Bool { !changes.isEmpty }
}

public enum AudioDeviceChangeEvent: Codable, Equatable, Sendable {
    case added(AudioDeviceSnapshot)
    case removed(identity: String, objectID: UInt32)
    case defaultInputChanged(identity: String?)
    case defaultOutputChanged(identity: String?)
    case snapshotChanged(AudioDeviceSnapshotDiff)
}
