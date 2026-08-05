import AudioLinkCore
import Foundation

public enum CorrelationMethod: String, Codable, CaseIterable, Sendable {
    case automatic
    case direct
    case fft
}

public enum CorrelationNormalization: String, Codable, CaseIterable, Sendable {
    case none
    /// Divides each lag by the energy of the overlapping portions of both inputs.
    case overlapEnergy
}

public enum CorrelationPeakSelection: String, Codable, CaseIterable, Sendable {
    case absolute
    case positive
    case negative
}

public enum CorrelationSequenceOutput: String, Codable, CaseIterable, Sendable {
    case none
    case searchedRange
    case full
}

public struct CorrelationConfiguration: Codable, Equatable, Sendable {
    public var method: CorrelationMethod
    public var normalization: CorrelationNormalization
    public var searchRange: SampleLagRange?
    public var peakSelection: CorrelationPeakSelection
    public var sequenceOutput: CorrelationSequenceOutput
    public var minimumOverlapRatio: Double
    public var directOperationLimit: Int64
    public var sidelobeExclusionRadius: Int
    public var interpolateSubsample: Bool
    public var minimumInputRMS: Double
    public var minimumPeakMagnitude: Double
    public var minimumPeakToSidelobeRatio: Double
    public var ambiguityTolerance: Double
    public var channel: Int

    public init(
        method: CorrelationMethod = .automatic,
        normalization: CorrelationNormalization = .overlapEnergy,
        searchRange: SampleLagRange? = nil,
        peakSelection: CorrelationPeakSelection = .absolute,
        sequenceOutput: CorrelationSequenceOutput = .searchedRange,
        minimumOverlapRatio: Double = 0.5,
        directOperationLimit: Int64 = 2_000_000,
        sidelobeExclusionRadius: Int = 8,
        interpolateSubsample: Bool = true,
        minimumInputRMS: Double = 1e-7,
        minimumPeakMagnitude: Double = 0.2,
        minimumPeakToSidelobeRatio: Double = 1.15,
        ambiguityTolerance: Double = 0.02,
        channel: Int = 0
    ) {
        self.method = method
        self.normalization = normalization
        self.searchRange = searchRange
        self.peakSelection = peakSelection
        self.sequenceOutput = sequenceOutput
        self.minimumOverlapRatio = minimumOverlapRatio
        self.directOperationLimit = directOperationLimit
        self.sidelobeExclusionRadius = sidelobeExclusionRadius
        self.interpolateSubsample = interpolateSubsample
        self.minimumInputRMS = minimumInputRMS
        self.minimumPeakMagnitude = minimumPeakMagnitude
        self.minimumPeakToSidelobeRatio = minimumPeakToSidelobeRatio
        self.ambiguityTolerance = ambiguityTolerance
        self.channel = channel
    }
}

public enum CorrelationAnalysisError: Error, Equatable, Sendable {
    case emptyReference
    case emptyObserved
    case nonFiniteReference(index: Int)
    case nonFiniteObserved(index: Int)
    case insufficientReferenceSignal(rms: Double, minimum: Double)
    case insufficientObservedSignal(rms: Double, minimum: Double)
    case invalidSearchRange(SampleLagRange)
    case searchRangeOutsideValidLags(requested: SampleLagRange, valid: SampleLagRange)
    case insufficientOverlap(required: Int, maximumAvailable: Int)
    case invalidConfiguration(String)
    case noPeakMatchingPolarity(CorrelationPeakSelection)
    case fftLengthOverflow
    case fftSetupFailure(length: Int)
    case sampleRateMismatch(reference: SampleRate, observed: SampleRate)
    case channelCountMismatch(reference: Int, observed: Int)
    case invalidChannel(requested: Int, available: Int)
    case cancelled
}

extension CorrelationAnalysisError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyReference:
            "The reference audio is empty."
        case .emptyObserved:
            "The recorded audio is empty."
        case .nonFiniteReference:
            "The reference audio contains NaN or infinity."
        case .nonFiniteObserved:
            "The recorded audio contains NaN or infinity."
        case .insufficientReferenceSignal:
            "The reference signal is too quiet for reliable correlation."
        case .insufficientObservedSignal:
            "The recorded signal is too quiet for reliable correlation."
        case .invalidSearchRange:
            "The correlation search range is invalid."
        case .searchRangeOutsideValidLags:
            "The requested delay range does not overlap the valid linear-correlation lags."
        case .insufficientOverlap:
            "The inputs do not have enough overlapping samples for this configuration."
        case .invalidConfiguration:
            "The correlation configuration is invalid."
        case .noPeakMatchingPolarity:
            "No correlation peak matches the requested polarity."
        case .fftLengthOverflow:
            "The inputs are too large to choose a safe FFT length."
        case .fftSetupFailure:
            "Accelerate could not create the required FFT setup."
        case .sampleRateMismatch:
            "Reference and recorded audio must have the same sample rate."
        case .channelCountMismatch:
            "Reference and recorded audio must have the same channel count."
        case .invalidChannel:
            "The requested analysis channel does not exist."
        case .cancelled:
            "Correlation analysis was cancelled."
        }
    }

    public var debugDescription: String {
        switch self {
        case let .nonFiniteReference(index), let .nonFiniteObserved(index):
            "Non-finite PCM sample at index \(index)."
        case let .insufficientReferenceSignal(rms, minimum),
             let .insufficientObservedSignal(rms, minimum):
            "Input RMS \(rms) is below configured minimum \(minimum)."
        case let .invalidSearchRange(range):
            "Search minimum \(range.minimum) is greater than maximum \(range.maximum)."
        case let .searchRangeOutsideValidLags(requested, valid):
            "Requested \(requested.minimum)...\(requested.maximum); valid \(valid.minimum)...\(valid.maximum)."
        case let .insufficientOverlap(required, maximumAvailable):
            "Required \(required) overlapping samples; at most \(maximumAvailable) are available."
        case let .invalidConfiguration(message):
            message
        case let .fftSetupFailure(length):
            "vDSP FFT setup creation failed for length \(length)."
        case let .sampleRateMismatch(reference, observed):
            "Reference is \(reference.hertz) Hz; observed is \(observed.hertz) Hz."
        case let .channelCountMismatch(reference, observed):
            "Reference has \(reference) channels; observed has \(observed) channels."
        case let .invalidChannel(requested, available):
            "Requested channel \(requested); available count is \(available)."
        default:
            errorDescription ?? String(describing: self)
        }
    }
}

public struct DelayAnalysisResult: Codable, Equatable, Sendable {
    public let delay: DelayEstimate
    public let correlation: CorrelationResult

    public init(delay: DelayEstimate, correlation: CorrelationResult) {
        self.delay = delay
        self.correlation = correlation
    }
}
