import Foundation

public enum CalibrationMethod: String, Codable, CaseIterable, Sendable {
    case manualKnownDelay
    case physicalLoopback
}

public struct CalibrationChannelMapping: Codable, Equatable, Hashable, Sendable {
    public let inputChannel: Int
    public let outputChannel: Int

    public init(inputChannel: Int, outputChannel: Int) {
        self.inputChannel = inputChannel
        self.outputChannel = outputChannel
    }
}

/// The fixed delay measured or entered for a route. Delays are canonical in
/// samples; milliseconds are derived only when a sample rate is available.
public struct CalibrationOffset: Codable, Equatable, Hashable, Sendable {
    public let sampleCount: SampleCount
    public let sampleRate: SampleRate

    public init(sampleCount: SampleCount, sampleRate: SampleRate) {
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
    }

    public var milliseconds: Double {
        Double(sampleCount.rawValue) / sampleRate.hertz * 1_000
    }
}

public struct CalibrationRouteDescriptor: Codable, Equatable, Hashable, Sendable {
    public let inputDeviceID: String
    public let outputDeviceID: String
    public let channelMapping: CalibrationChannelMapping
    public let sampleRate: SampleRate
    public let bufferFrameCount: Int

    public init(
        inputDeviceID: String,
        outputDeviceID: String,
        channelMapping: CalibrationChannelMapping,
        sampleRate: SampleRate,
        bufferFrameCount: Int
    ) {
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID
        self.channelMapping = channelMapping
        self.sampleRate = sampleRate
        self.bufferFrameCount = bufferFrameCount
    }
}

public enum CalibrationMatchFailure: Error, Codable, Equatable, Sendable {
    case inputDeviceMismatch(expected: String, actual: String)
    case outputDeviceMismatch(expected: String, actual: String)
    case channelMappingMismatch(expected: CalibrationChannelMapping, actual: CalibrationChannelMapping)
    case sampleRateMismatch(expected: SampleRate, actual: SampleRate)
    case bufferSizeMismatch(expected: Int, actual: Int)
    case invalidProfile(String)
}

extension CalibrationMatchFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .inputDeviceMismatch: "The calibration profile input device does not match the current route."
        case .outputDeviceMismatch: "The calibration profile output device does not match the current route."
        case .channelMappingMismatch: "The calibration profile channel mapping does not match the current route."
        case .sampleRateMismatch: "The calibration profile sample rate does not match the current route."
        case .bufferSizeMismatch: "The calibration profile buffer size does not match the current route."
        case let .invalidProfile(message): message
        }
    }
}

public struct CalibrationProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let profileName: String
    public let inputDevice: DeviceDescriptor
    public let outputDevice: DeviceDescriptor
    public let channelMapping: CalibrationChannelMapping
    public let sampleRate: SampleRate
    public let bufferFrameCount: Int
    public let knownFixedDelay: CalibrationOffset
    public let measurementDate: Date
    public let notes: String
    /// Confidence is an explainable 0...1 quality of the calibration procedure.
    public let confidence: Double
    public let calibrationMethod: CalibrationMethod
    public let subtractOffsetByDefault: Bool

    public init(
        id: UUID = UUID(),
        profileName: String,
        inputDevice: DeviceDescriptor,
        outputDevice: DeviceDescriptor,
        channelMapping: CalibrationChannelMapping,
        sampleRate: SampleRate,
        bufferFrameCount: Int,
        knownFixedDelay: CalibrationOffset,
        measurementDate: Date = Date(),
        notes: String = "",
        confidence: Double,
        calibrationMethod: CalibrationMethod,
        subtractOffsetByDefault: Bool = true
    ) {
        self.id = id
        self.profileName = profileName
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
        self.channelMapping = channelMapping
        self.sampleRate = sampleRate
        self.bufferFrameCount = bufferFrameCount
        self.knownFixedDelay = knownFixedDelay
        self.measurementDate = measurementDate
        self.notes = notes
        self.confidence = confidence
        self.calibrationMethod = calibrationMethod
        self.subtractOffsetByDefault = subtractOffsetByDefault
    }

    public func validate() throws {
        guard !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalibrationMatchFailure.invalidProfile("Calibration profile name cannot be empty.")
        }
        guard inputDevice.supportsInput, outputDevice.supportsOutput else {
            throw CalibrationMatchFailure.invalidProfile("The profile devices do not provide the required input/output capabilities.")
        }
        guard !inputDevice.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !outputDevice.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalibrationMatchFailure.invalidProfile("Calibration profile devices must have stable identifiers.")
        }
        guard channelMapping.inputChannel >= 0, channelMapping.outputChannel >= 0 else {
            throw CalibrationMatchFailure.invalidProfile("Calibration channel indices cannot be negative.")
        }
        guard bufferFrameCount > 0 else {
            throw CalibrationMatchFailure.invalidProfile("Calibration buffer size must be greater than zero.")
        }
        guard knownFixedDelay.sampleRate == sampleRate else {
            throw CalibrationMatchFailure.invalidProfile("The calibration offset sample rate must equal the profile sample rate.")
        }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw CalibrationMatchFailure.invalidProfile("Calibration confidence must be between 0 and 1.")
        }
    }

    public func matches(_ route: CalibrationRouteDescriptor) throws {
        try validate()
        guard inputDevice.id == route.inputDeviceID else {
            throw CalibrationMatchFailure.inputDeviceMismatch(expected: inputDevice.id, actual: route.inputDeviceID)
        }
        guard outputDevice.id == route.outputDeviceID else {
            throw CalibrationMatchFailure.outputDeviceMismatch(expected: outputDevice.id, actual: route.outputDeviceID)
        }
        guard channelMapping == route.channelMapping else {
            throw CalibrationMatchFailure.channelMappingMismatch(expected: channelMapping, actual: route.channelMapping)
        }
        guard sampleRate == route.sampleRate else {
            throw CalibrationMatchFailure.sampleRateMismatch(expected: sampleRate, actual: route.sampleRate)
        }
        guard bufferFrameCount == route.bufferFrameCount else {
            throw CalibrationMatchFailure.bufferSizeMismatch(expected: bufferFrameCount, actual: route.bufferFrameCount)
        }
    }
}

public struct CalibratedDelayResult: Codable, Equatable, Sendable {
    public let rawDelay: DelayEstimate
    public let calibratedDelay: DelayEstimate?
    public let profileID: UUID
    public let offset: CalibrationOffset
    public let offsetApplied: Bool

    public init(
        rawDelay: DelayEstimate,
        calibratedDelay: DelayEstimate?,
        profileID: UUID,
        offset: CalibrationOffset,
        offsetApplied: Bool
    ) {
        self.rawDelay = rawDelay
        self.calibratedDelay = calibratedDelay
        self.profileID = profileID
        self.offset = offset
        self.offsetApplied = offsetApplied
    }
}

public enum CalibrationApplicator {
    public static func apply(
        rawDelay: DelayEstimate,
        profile: CalibrationProfile,
        route: CalibrationRouteDescriptor,
        subtractOffset: Bool? = nil
    ) throws -> CalibratedDelayResult {
        try profile.matches(route)
        guard rawDelay.sampleRate == profile.sampleRate else {
            throw CalibrationMatchFailure.sampleRateMismatch(
                expected: profile.sampleRate,
                actual: rawDelay.sampleRate
            )
        }
        let shouldApply = subtractOffset ?? profile.subtractOffsetByDefault
        let calibrated: DelayEstimate?
        if shouldApply {
            let rawFractional = rawDelay.fractionalSampleOffset ?? Double(rawDelay.sampleOffset.rawValue)
            let offset = Double(profile.knownFixedDelay.sampleCount.rawValue)
            calibrated = DelayEstimate(
                sampleOffset: SampleCount(rawValue: rawDelay.sampleOffset.rawValue - profile.knownFixedDelay.sampleCount.rawValue),
                sampleRate: rawDelay.sampleRate,
                confidence: rawDelay.confidence,
                fractionalSampleOffset: rawFractional - offset,
                peakAmplitude: rawDelay.peakAmplitude,
                peakToSidelobeRatio: rawDelay.peakToSidelobeRatio,
                isReliable: rawDelay.isReliable
            )
        } else {
            calibrated = nil
        }
        return CalibratedDelayResult(
            rawDelay: rawDelay,
            calibratedDelay: calibrated,
            profileID: profile.id,
            offset: profile.knownFixedDelay,
            offsetApplied: shouldApply
        )
    }
}
