import Foundation

public struct AudioFormatDescriptor: Codable, Equatable, Hashable, Sendable {
    public let sampleRate: SampleRate
    public let channelCount: Int
    public let bitDepth: Int
    public let isInterleaved: Bool

    public init(sampleRate: SampleRate, channelCount: Int, bitDepth: Int, isInterleaved: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.isInterleaved = isInterleaved
    }
}

public struct DeviceDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Transport: String, Codable, CaseIterable, Sendable {
        case builtIn
        case usb
        case bluetooth
        case aggregate
        case virtual
        case network
        case unknown
    }

    public let id: String
    public let name: String
    public let manufacturer: String?
    public let transport: Transport
    public let supportsInput: Bool
    public let supportsOutput: Bool

    public init(
        id: String,
        name: String,
        manufacturer: String? = nil,
        transport: Transport = .unknown,
        supportsInput: Bool,
        supportsOutput: Bool
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.transport = transport
        self.supportsInput = supportsInput
        self.supportsOutput = supportsOutput
    }
}

public struct MeasurementConfiguration: Codable, Equatable, Sendable {
    public enum ExcitationSignal: String, Codable, CaseIterable, Sendable {
        case impulse
        case sineSweep
        case maximumLengthSequence
    }

    public let format: AudioFormatDescriptor
    public let signal: ExcitationSignal
    public let measurementDuration: DurationSeconds
    public let repetitions: Int
    public let inputDevice: DeviceDescriptor?
    public let outputDevice: DeviceDescriptor?

    public init(
        format: AudioFormatDescriptor,
        signal: ExcitationSignal,
        measurementDuration: DurationSeconds,
        repetitions: Int,
        inputDevice: DeviceDescriptor? = nil,
        outputDevice: DeviceDescriptor? = nil
    ) {
        self.format = format
        self.signal = signal
        self.measurementDuration = measurementDuration
        self.repetitions = repetitions
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
    }
}

public struct DelayEstimate: Codable, Equatable, Sendable {
    public let sampleOffset: SampleCount
    public let sampleRate: SampleRate
    public let confidence: Double
    /// Sub-sample lag when interpolation was possible. `nil` preserves the
    /// integer-only semantics used by older stored measurements.
    public let fractionalSampleOffset: Double?
    public let peakAmplitude: Double?
    public let peakToSidelobeRatio: Double?
    public let isReliable: Bool?

    public init(
        sampleOffset: SampleCount,
        sampleRate: SampleRate,
        confidence: Double,
        fractionalSampleOffset: Double? = nil,
        peakAmplitude: Double? = nil,
        peakToSidelobeRatio: Double? = nil,
        isReliable: Bool? = nil
    ) {
        self.sampleOffset = sampleOffset
        self.sampleRate = sampleRate
        self.confidence = confidence
        self.fractionalSampleOffset = fractionalSampleOffset
        self.peakAmplitude = peakAmplitude
        self.peakToSidelobeRatio = peakToSidelobeRatio
        self.isReliable = isReliable
    }

    public var duration: DurationSeconds { sampleOffset.duration(at: sampleRate) }
    public var fractionalMilliseconds: Double {
        (fractionalSampleOffset ?? Double(sampleOffset.rawValue)) / sampleRate.hertz * 1_000
    }
}

public struct SampleLagRange: Codable, Equatable, Hashable, Sendable {
    public let minimum: Int64
    public let maximum: Int64

    public init(minimum: Int64, maximum: Int64) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var count: Int64 {
        guard maximum >= minimum else { return 0 }
        let (difference, subtractionOverflow) = maximum.subtractingReportingOverflow(minimum)
        guard !subtractionOverflow else { return Int64.max }
        let (result, additionOverflow) = difference.addingReportingOverflow(1)
        return additionOverflow ? Int64.max : result
    }
    public func contains(_ lag: Int64) -> Bool { lag >= minimum && lag <= maximum }
}

public enum CorrelationImplementation: String, Codable, CaseIterable, Sendable {
    case direct
    case fft
}

public enum DelayAnalysisValidity: String, Codable, CaseIterable, Sendable {
    case valid
    case lowConfidence
    case ambiguous
}

public enum SubsampleInterpolationStatus: String, Codable, CaseIterable, Sendable {
    case applied
    case disabledByConfiguration
    case peakAtSequenceBoundary
    case degenerateNeighborhood
}

public struct CorrelationPeak: Codable, Equatable, Sendable {
    public let lag: SampleCount
    public let fractionalLag: Double?
    /// Signed correlation value. A negative value identifies inverted polarity.
    public let value: Double
    public let overlapCount: SampleCount

    public init(
        lag: SampleCount,
        fractionalLag: Double? = nil,
        value: Double,
        overlapCount: SampleCount
    ) {
        self.lag = lag
        self.fractionalLag = fractionalLag
        self.value = value
        self.overlapCount = overlapCount
    }

    public var magnitude: Double { abs(value) }
}

public struct CorrelationSequence: Codable, Equatable, Sendable {
    public let firstLag: Int64
    public let values: [Float]

    public init(firstLag: Int64, values: [Float]) {
        self.firstLag = firstLag
        self.values = values
    }

    public var lastLag: Int64 { firstLag + Int64(values.count) - 1 }

    public func value(atLag lag: Int64) -> Float? {
        let index = lag - firstLag
        guard index >= 0, index < Int64(values.count) else { return nil }
        return values[Int(index)]
    }
}

public struct AnalysisDiagnostics: Codable, Equatable, Sendable {
    public let implementation: CorrelationImplementation
    public let validity: DelayAnalysisValidity
    public let validLagRange: SampleLagRange
    public let searchedLagRange: SampleLagRange
    public let searchRangeWasClamped: Bool
    public let peakAtSearchBoundary: Bool
    public let referenceRMS: Double
    public let observedRMS: Double
    public let minimumOverlapCount: SampleCount
    public let fftLength: Int?
    public let estimatedWorkingSetBytes: Int64
    public let interpolationStatus: SubsampleInterpolationStatus
    public let notes: [String]

    public init(
        implementation: CorrelationImplementation,
        validity: DelayAnalysisValidity,
        validLagRange: SampleLagRange,
        searchedLagRange: SampleLagRange,
        searchRangeWasClamped: Bool,
        peakAtSearchBoundary: Bool,
        referenceRMS: Double,
        observedRMS: Double,
        minimumOverlapCount: SampleCount,
        fftLength: Int? = nil,
        estimatedWorkingSetBytes: Int64,
        interpolationStatus: SubsampleInterpolationStatus,
        notes: [String] = []
    ) {
        self.implementation = implementation
        self.validity = validity
        self.validLagRange = validLagRange
        self.searchedLagRange = searchedLagRange
        self.searchRangeWasClamped = searchRangeWasClamped
        self.peakAtSearchBoundary = peakAtSearchBoundary
        self.referenceRMS = referenceRMS
        self.observedRMS = observedRMS
        self.minimumOverlapCount = minimumOverlapCount
        self.fftLength = fftLength
        self.estimatedWorkingSetBytes = estimatedWorkingSetBytes
        self.interpolationStatus = interpolationStatus
        self.notes = notes
    }
}

public struct CorrelationResult: Codable, Equatable, Sendable {
    public let peakOffset: SampleCount
    public let normalizedPeak: Double
    public let peakToSidelobeRatio: Double
    public let confidence: Double
    public let primaryPeak: CorrelationPeak?
    public let secondaryPeak: CorrelationPeak?
    public let sequence: CorrelationSequence?
    public let diagnostics: AnalysisDiagnostics?

    public init(
        peakOffset: SampleCount,
        normalizedPeak: Double,
        peakToSidelobeRatio: Double,
        confidence: Double,
        primaryPeak: CorrelationPeak? = nil,
        secondaryPeak: CorrelationPeak? = nil,
        sequence: CorrelationSequence? = nil,
        diagnostics: AnalysisDiagnostics? = nil
    ) {
        self.peakOffset = peakOffset
        self.normalizedPeak = normalizedPeak
        self.peakToSidelobeRatio = peakToSidelobeRatio
        self.confidence = confidence
        self.primaryPeak = primaryPeak
        self.secondaryPeak = secondaryPeak
        self.sequence = sequence
        self.diagnostics = diagnostics
    }
}

public struct MeasurementStatistics: Codable, Equatable, Sendable {
    public let sampleSize: Int
    public let meanDelay: SampleCount
    public let medianDelay: SampleCount
    public let minimumDelay: SampleCount
    public let maximumDelay: SampleCount
    public let jitterStandardDeviation: DurationSeconds
    public let clockDrift: PartsPerMillion?

    public init(
        sampleSize: Int,
        meanDelay: SampleCount,
        medianDelay: SampleCount,
        minimumDelay: SampleCount,
        maximumDelay: SampleCount,
        jitterStandardDeviation: DurationSeconds,
        clockDrift: PartsPerMillion? = nil
    ) {
        self.sampleSize = sampleSize
        self.meanDelay = meanDelay
        self.medianDelay = medianDelay
        self.minimumDelay = minimumDelay
        self.maximumDelay = maximumDelay
        self.jitterStandardDeviation = jitterStandardDeviation
        self.clockDrift = clockDrift
    }
}

public struct MeasurementRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let completedAt: Date?
    public let delayEstimate: DelayEstimate?
    public let correlation: CorrelationResult?
    public let quality: MeasurementQuality?
    public let calibration: CalibratedDelayResult?
    public let error: MeasurementError?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        completedAt: Date? = nil,
        delayEstimate: DelayEstimate? = nil,
        correlation: CorrelationResult? = nil,
        quality: MeasurementQuality? = nil,
        calibration: CalibratedDelayResult? = nil,
        error: MeasurementError? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.delayEstimate = delayEstimate
        self.correlation = correlation
        self.quality = quality
        self.calibration = calibration
        self.error = error
    }
}

public struct MeasurementSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let name: String
    public let configuration: MeasurementConfiguration
    public let runs: [MeasurementRun]
    public let statistics: MeasurementStatistics?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        name: String,
        configuration: MeasurementConfiguration,
        runs: [MeasurementRun] = [],
        statistics: MeasurementStatistics? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.name = name
        self.configuration = configuration
        self.runs = runs
        self.statistics = statistics
    }
}
