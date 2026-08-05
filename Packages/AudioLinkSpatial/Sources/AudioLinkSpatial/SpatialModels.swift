import AudioLinkCore
import Foundation

public enum SpatialLengthUnit: String, Codable, CaseIterable, Sendable { case meters, feet }

public struct SpatialCoordinate: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double?
    public let unit: SpatialLengthUnit
    public init(x: Double, y: Double, z: Double? = nil, unit: SpatialLengthUnit = .meters) throws {
        guard x.isFinite, y.isFinite, z?.isFinite ?? true else { throw SpatialValidationError.invalidCoordinate }
        self.x = x; self.y = y; self.z = z; self.unit = unit
    }
    public func converted(to target: SpatialLengthUnit) -> SpatialCoordinate {
        guard target != unit else { return self }
        let factor = unit == .meters ? 3.280839895013123 : 0.3048
        return SpatialCoordinate(uncheckedX: x * factor, y: y * factor, z: z.map { $0 * factor }, unit: target)
    }
    private init(uncheckedX x: Double, y: Double, z: Double?, unit: SpatialLengthUnit) { self.x = x; self.y = y; self.z = z; self.unit = unit }
    public func distance(to other: SpatialCoordinate) -> Double {
        let rhs = other.converted(to: unit)
        let dz = (z ?? 0) - (rhs.z ?? 0)
        return sqrt((x - rhs.x) * (x - rhs.x) + (y - rhs.y) * (y - rhs.y) + dz * dz)
    }
}

public struct RoomGeometry: Codable, Equatable, Sendable {
    public let width: Double
    public let depth: Double
    public let height: Double?
    public let unit: SpatialLengthUnit
    public init(width: Double, depth: Double, height: Double? = nil, unit: SpatialLengthUnit = .meters) throws {
        guard width > 0, depth > 0, (height.map({ $0 > 0 }) ?? true) else { throw SpatialValidationError.invalidGeometry }
        self.width = width; self.depth = depth; self.height = height; self.unit = unit
    }
}

public struct SourcePosition: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let coordinate: SpatialCoordinate
    public init(id: UUID = UUID(), name: String, coordinate: SpatialCoordinate) { self.id = id; self.name = name; self.coordinate = coordinate }
}

public struct ReceiverPosition: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let coordinate: SpatialCoordinate
    public init(id: UUID = UUID(), name: String, coordinate: SpatialCoordinate) { self.id = id; self.name = name; self.coordinate = coordinate }
}

public struct MeasurementPosition: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let receiver: ReceiverPosition
    public let order: Int
    public var notes: String
    public var completed: Bool
    public init(id: UUID = UUID(), label: String, receiver: ReceiverPosition, order: Int, notes: String = "", completed: Bool = false) {
        self.id = id; self.label = label; self.receiver = receiver; self.order = order; self.notes = notes; self.completed = completed
    }
}

public struct AcousticSpaceProject: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var geometry: RoomGeometry?
    public var source: SourcePosition
    public var positions: [MeasurementPosition]
    public var createdAt: Date
    public var notes: String
    public init(id: UUID = UUID(), name: String, geometry: RoomGeometry? = nil, source: SourcePosition, positions: [MeasurementPosition] = [], createdAt: Date = Date(), notes: String = "") {
        self.id = id; self.name = name; self.geometry = geometry; self.source = source; self.positions = positions; self.createdAt = createdAt; self.notes = notes
    }
}

public enum SpatialValidationError: Error, Codable, Equatable, Sendable, LocalizedError {
    case invalidCoordinate, invalidGeometry, invalidIR, invalidFrequencyBand
    public var errorDescription: String? {
        switch self { case .invalidCoordinate: "Spatial coordinate contains a non-finite value."; case .invalidGeometry: "Room dimensions must be positive."; case .invalidIR: "Impulse response is empty or has an invalid sample rate."; case .invalidFrequencyBand: "Frequency band is outside the supported range." }
    }
}

public struct AcousticMetricValue: Codable, Equatable, Sendable {
    public let value: Double?
    public let unit: String
    public let valid: Bool
    public let confidence: Double
    public let method: String
    public let explanation: String
    public init(value: Double?, unit: String, valid: Bool, confidence: Double, method: String, explanation: String) {
        self.value = value; self.unit = unit; self.valid = valid; self.confidence = confidence; self.method = method; self.explanation = explanation
    }
}

public struct EarlyReflectionCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let delaySeconds: Double
    public let relativeLevelDecibels: Double
    public let evidence: String
    public init(id: UUID = UUID(), delaySeconds: Double, relativeLevelDecibels: Double, evidence: String) { self.id = id; self.delaySeconds = delaySeconds; self.relativeLevelDecibels = relativeLevelDecibels; self.evidence = evidence }
}

public struct AcousticMetricSet: Codable, Equatable, Sendable {
    public let peakArrivalTime: AcousticMetricValue
    public let directSoundLevel: AcousticMetricValue
    public let edt: AcousticMetricValue
    public let rt20: AcousticMetricValue
    public let rt30: AcousticMetricValue
    public let estimatedRT60: AcousticMetricValue
    public let c50: AcousticMetricValue
    public let c80: AcousticMetricValue
    public let d50: AcousticMetricValue
    public let centerTime: AcousticMetricValue
    public let signalToNoiseRatio: AcousticMetricValue
    public let earlyReflections: [EarlyReflectionCandidate]
    public init(peakArrivalTime: AcousticMetricValue, directSoundLevel: AcousticMetricValue, edt: AcousticMetricValue, rt20: AcousticMetricValue, rt30: AcousticMetricValue, estimatedRT60: AcousticMetricValue, c50: AcousticMetricValue, c80: AcousticMetricValue, d50: AcousticMetricValue, centerTime: AcousticMetricValue, signalToNoiseRatio: AcousticMetricValue, earlyReflections: [EarlyReflectionCandidate] = []) {
        self.peakArrivalTime = peakArrivalTime; self.directSoundLevel = directSoundLevel; self.edt = edt; self.rt20 = rt20; self.rt30 = rt30; self.estimatedRT60 = estimatedRT60; self.c50 = c50; self.c80 = c80; self.d50 = d50; self.centerTime = centerTime; self.signalToNoiseRatio = signalToNoiseRatio; self.earlyReflections = earlyReflections
    }
}

public struct ImpulseResponseMeasurement: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let positionID: UUID
    public let sampleRate: SampleRate
    public let samples: [Float]
    public let metrics: AcousticMetricSet
    public let sweepConfigurationSummary: [String: String]
    public let processingLog: [String]
    public let microphoneModel: String?
    public let microphoneOrientation: String?
    public let sourceReceiverDistanceMeters: Double?
    public let qualityExplanation: String
    public init(id: UUID = UUID(), positionID: UUID, sampleRate: SampleRate, samples: [Float], metrics: AcousticMetricSet, sweepConfigurationSummary: [String: String] = [:], processingLog: [String] = [], microphoneModel: String? = nil, microphoneOrientation: String? = nil, sourceReceiverDistanceMeters: Double? = nil, qualityExplanation: String = "") {
        self.id = id; self.positionID = positionID; self.sampleRate = sampleRate; self.samples = samples; self.metrics = metrics; self.sweepConfigurationSummary = sweepConfigurationSummary; self.processingLog = processingLog; self.microphoneModel = microphoneModel; self.microphoneOrientation = microphoneOrientation; self.sourceReceiverDistanceMeters = sourceReceiverDistanceMeters; self.qualityExplanation = qualityExplanation
    }
}

public struct SpatialMapSample: Codable, Equatable, Sendable { public let positionID: UUID; public let coordinate: SpatialCoordinate; public let metric: Double?; public let valid: Bool; public init(positionID: UUID, coordinate: SpatialCoordinate, metric: Double?, valid: Bool) { self.positionID = positionID; self.coordinate = coordinate; self.metric = metric; self.valid = valid } }

public struct SpatialMap: Codable, Equatable, Sendable {
    public let metricName: String
    public let bandHertz: ClosedRange<Double>?
    public let samples: [SpatialMapSample]
    public let interpolated: [SpatialMapSample]
    public let interpolationMethod: String?
    public let warning: String?
    public init(metricName: String, bandHertz: ClosedRange<Double>? = nil, samples: [SpatialMapSample], interpolated: [SpatialMapSample] = [], interpolationMethod: String? = nil, warning: String? = nil) { self.metricName = metricName; self.bandHertz = bandHertz; self.samples = samples; self.interpolated = interpolated; self.interpolationMethod = interpolationMethod; self.warning = warning }
}

public struct AcousticComparison: Codable, Equatable, Sendable {
    public let positionIDs: [UUID]
    public let metricDifferences: [String: Double]
    public let notes: [String]
    public init(positionIDs: [UUID], metricDifferences: [String: Double], notes: [String] = []) { self.positionIDs = positionIDs; self.metricDifferences = metricDifferences; self.notes = notes }
}
