import AudioLinkCore
import Foundation

/// Centralized empirical policy for measurement-quality interpretation.
/// Mathematical metrics are defined by the analyzer; these boundaries are
/// deliberately data so real-device calibration can replace them later.
public struct MeasurementQualityThresholds: Codable, Equatable, Sendable {
    public static let standard = Self()

    public var invalidInputRMS: Double
    public var quietInputRMS: Double
    public var healthyInputRMS: Double
    public var minimumUsableCorrelation: Double
    public var goodCorrelation: Double
    public var excellentCorrelation: Double
    public var questionablePrimaryToSecondaryRatio: Double
    public var goodPrimaryToSecondaryRatio: Double
    public var excellentPrimaryToSecondaryRatio: Double
    public var questionablePeakToSidelobeRatio: Double
    public var goodPeakToSidelobeRatio: Double
    public var excellentPeakToSidelobeRatio: Double
    public var poorSignalToNoiseDecibels: Double
    public var goodSignalToNoiseDecibels: Double
    public var excellentSignalToNoiseDecibels: Double
    public var clippingWarningRatio: Double
    public var clippingSevereRatio: Double
    public var dcOffsetWarningMagnitude: Double
    public var dcOffsetSevereMagnitude: Double
    public var coverageWarningRatio: Double
    public var coverageSevereRatio: Double
    public var goodPeakWidthSamples: Double
    public var poorPeakWidthSamples: Double
    public var goodLocalSharpness: Double
    public var excellentLocalSharpness: Double
    public var searchBoundaryWarningSamples: Int64
    public var searchBoundaryGoodSamples: Int64
    public var channelDelayWarningSamples: Double
    public var channelDelaySevereSamples: Double
    public var channelPeakWarningDifference: Double
    public var channelPeakSevereDifference: Double
    public var ambiguousPeakRelativeMagnitude: Double
    public var repeatedPeakRelativeMagnitude: Double
    public var candidateMinimumRelativeMagnitude: Double
    public var maximumPeakCandidates: Int
    public var candidateExclusionRadius: Int64
    public var periodicSpacingToleranceRatio: Double
    public var periodicSpacingToleranceSamples: Int64
    public var excellentScoreMinimum: Double
    public var goodScoreMinimum: Double
    public var questionableScoreMinimum: Double
    public var goodMetricNormalizedScore: Double
    public var errorScoreCap: Double
    public var uncertaintyScoreCap: Double
    public var warningScoreCap: Double
    public var finiteSNRLimitDecibels: Double
    public var weights: QualityMetricWeights

    public init(
        invalidInputRMS: Double = 1e-7,
        quietInputRMS: Double = 0.005,
        healthyInputRMS: Double = 0.03,
        minimumUsableCorrelation: Double = 0.2,
        goodCorrelation: Double = 0.75,
        excellentCorrelation: Double = 0.93,
        questionablePrimaryToSecondaryRatio: Double = 1.03,
        goodPrimaryToSecondaryRatio: Double = 1.2,
        excellentPrimaryToSecondaryRatio: Double = 1.8,
        questionablePeakToSidelobeRatio: Double = 2,
        goodPeakToSidelobeRatio: Double = 5,
        excellentPeakToSidelobeRatio: Double = 12,
        poorSignalToNoiseDecibels: Double = 6,
        goodSignalToNoiseDecibels: Double = 20,
        excellentSignalToNoiseDecibels: Double = 35,
        clippingWarningRatio: Double = 0.000_1,
        clippingSevereRatio: Double = 0.01,
        dcOffsetWarningMagnitude: Double = 0.02,
        dcOffsetSevereMagnitude: Double = 0.1,
        coverageWarningRatio: Double = 0.95,
        coverageSevereRatio: Double = 0.8,
        goodPeakWidthSamples: Double = 8,
        poorPeakWidthSamples: Double = 32,
        goodLocalSharpness: Double = 0.12,
        excellentLocalSharpness: Double = 0.3,
        searchBoundaryWarningSamples: Int64 = 8,
        searchBoundaryGoodSamples: Int64 = 64,
        channelDelayWarningSamples: Double = 2,
        channelDelaySevereSamples: Double = 10,
        channelPeakWarningDifference: Double = 0.1,
        channelPeakSevereDifference: Double = 0.3,
        ambiguousPeakRelativeMagnitude: Double = 0.97,
        repeatedPeakRelativeMagnitude: Double = 0.9,
        candidateMinimumRelativeMagnitude: Double = 0.2,
        maximumPeakCandidates: Int = 8,
        candidateExclusionRadius: Int64 = 8,
        periodicSpacingToleranceRatio: Double = 0.05,
        periodicSpacingToleranceSamples: Int64 = 2,
        excellentScoreMinimum: Double = 0.85,
        goodScoreMinimum: Double = 0.7,
        questionableScoreMinimum: Double = 0.5,
        goodMetricNormalizedScore: Double = 0.75,
        errorScoreCap: Double = 0.49,
        uncertaintyScoreCap: Double = 0.69,
        warningScoreCap: Double = 0.84,
        finiteSNRLimitDecibels: Double = 120,
        weights: QualityMetricWeights = .standard
    ) {
        self.invalidInputRMS = invalidInputRMS
        self.quietInputRMS = quietInputRMS
        self.healthyInputRMS = healthyInputRMS
        self.minimumUsableCorrelation = minimumUsableCorrelation
        self.goodCorrelation = goodCorrelation
        self.excellentCorrelation = excellentCorrelation
        self.questionablePrimaryToSecondaryRatio = questionablePrimaryToSecondaryRatio
        self.goodPrimaryToSecondaryRatio = goodPrimaryToSecondaryRatio
        self.excellentPrimaryToSecondaryRatio = excellentPrimaryToSecondaryRatio
        self.questionablePeakToSidelobeRatio = questionablePeakToSidelobeRatio
        self.goodPeakToSidelobeRatio = goodPeakToSidelobeRatio
        self.excellentPeakToSidelobeRatio = excellentPeakToSidelobeRatio
        self.poorSignalToNoiseDecibels = poorSignalToNoiseDecibels
        self.goodSignalToNoiseDecibels = goodSignalToNoiseDecibels
        self.excellentSignalToNoiseDecibels = excellentSignalToNoiseDecibels
        self.clippingWarningRatio = clippingWarningRatio
        self.clippingSevereRatio = clippingSevereRatio
        self.dcOffsetWarningMagnitude = dcOffsetWarningMagnitude
        self.dcOffsetSevereMagnitude = dcOffsetSevereMagnitude
        self.coverageWarningRatio = coverageWarningRatio
        self.coverageSevereRatio = coverageSevereRatio
        self.goodPeakWidthSamples = goodPeakWidthSamples
        self.poorPeakWidthSamples = poorPeakWidthSamples
        self.goodLocalSharpness = goodLocalSharpness
        self.excellentLocalSharpness = excellentLocalSharpness
        self.searchBoundaryWarningSamples = searchBoundaryWarningSamples
        self.searchBoundaryGoodSamples = searchBoundaryGoodSamples
        self.channelDelayWarningSamples = channelDelayWarningSamples
        self.channelDelaySevereSamples = channelDelaySevereSamples
        self.channelPeakWarningDifference = channelPeakWarningDifference
        self.channelPeakSevereDifference = channelPeakSevereDifference
        self.ambiguousPeakRelativeMagnitude = ambiguousPeakRelativeMagnitude
        self.repeatedPeakRelativeMagnitude = repeatedPeakRelativeMagnitude
        self.candidateMinimumRelativeMagnitude = candidateMinimumRelativeMagnitude
        self.maximumPeakCandidates = maximumPeakCandidates
        self.candidateExclusionRadius = candidateExclusionRadius
        self.periodicSpacingToleranceRatio = periodicSpacingToleranceRatio
        self.periodicSpacingToleranceSamples = periodicSpacingToleranceSamples
        self.excellentScoreMinimum = excellentScoreMinimum
        self.goodScoreMinimum = goodScoreMinimum
        self.questionableScoreMinimum = questionableScoreMinimum
        self.goodMetricNormalizedScore = goodMetricNormalizedScore
        self.errorScoreCap = errorScoreCap
        self.uncertaintyScoreCap = uncertaintyScoreCap
        self.warningScoreCap = warningScoreCap
        self.finiteSNRLimitDecibels = finiteSNRLimitDecibels
        self.weights = weights
    }
}

public struct QualityMetricWeights: Codable, Equatable, Sendable {
    public static let standard = Self()

    public var primaryCorrelation: Double
    public var primaryToSecondaryRatio: Double
    public var peakToSidelobeRatio: Double
    public var peakWidth: Double
    public var localSharpness: Double
    public var inputLevel: Double
    public var signalToNoise: Double
    public var clipping: Double
    public var dcOffset: Double
    public var referenceCoverage: Double
    public var searchBoundary: Double
    public var channelAgreement: Double

    public init(
        primaryCorrelation: Double = 0.20,
        primaryToSecondaryRatio: Double = 0.12,
        peakToSidelobeRatio: Double = 0.10,
        peakWidth: Double = 0.05,
        localSharpness: Double = 0.08,
        inputLevel: Double = 0.07,
        signalToNoise: Double = 0.15,
        clipping: Double = 0.08,
        dcOffset: Double = 0.04,
        referenceCoverage: Double = 0.05,
        searchBoundary: Double = 0.03,
        channelAgreement: Double = 0.03
    ) {
        self.primaryCorrelation = primaryCorrelation
        self.primaryToSecondaryRatio = primaryToSecondaryRatio
        self.peakToSidelobeRatio = peakToSidelobeRatio
        self.peakWidth = peakWidth
        self.localSharpness = localSharpness
        self.inputLevel = inputLevel
        self.signalToNoise = signalToNoise
        self.clipping = clipping
        self.dcOffset = dcOffset
        self.referenceCoverage = referenceCoverage
        self.searchBoundary = searchBoundary
        self.channelAgreement = channelAgreement
    }
}

public enum MeasurementQualityError: Error, Equatable, Sendable {
    case invalidThresholds(String)
}

extension MeasurementQualityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidThresholds:
            "The measurement-quality threshold policy is invalid."
        }
    }

    public var debugDescription: String {
        switch self {
        case let .invalidThresholds(message): message
        }
    }
}

extension MeasurementQualityThresholds {
    public func validate() throws {
        let finiteValues = [
            invalidInputRMS, quietInputRMS, healthyInputRMS,
            minimumUsableCorrelation, goodCorrelation, excellentCorrelation,
            questionablePrimaryToSecondaryRatio, goodPrimaryToSecondaryRatio,
            excellentPrimaryToSecondaryRatio, questionablePeakToSidelobeRatio,
            goodPeakToSidelobeRatio, excellentPeakToSidelobeRatio,
            poorSignalToNoiseDecibels, goodSignalToNoiseDecibels,
            excellentSignalToNoiseDecibels, clippingWarningRatio,
            clippingSevereRatio, dcOffsetWarningMagnitude, dcOffsetSevereMagnitude,
            coverageWarningRatio, coverageSevereRatio, goodPeakWidthSamples,
            poorPeakWidthSamples, goodLocalSharpness, excellentLocalSharpness,
            channelDelayWarningSamples, channelDelaySevereSamples,
            channelPeakWarningDifference, channelPeakSevereDifference,
            ambiguousPeakRelativeMagnitude, repeatedPeakRelativeMagnitude,
            candidateMinimumRelativeMagnitude, periodicSpacingToleranceRatio,
            excellentScoreMinimum, goodScoreMinimum, questionableScoreMinimum,
            goodMetricNormalizedScore, errorScoreCap, uncertaintyScoreCap,
            warningScoreCap, finiteSNRLimitDecibels
        ]
        guard finiteValues.allSatisfy(\.isFinite) else {
            throw MeasurementQualityError.invalidThresholds("Every floating-point threshold must be finite.")
        }
        guard invalidInputRMS > 0,
              invalidInputRMS < quietInputRMS,
              quietInputRMS < healthyInputRMS else {
            throw MeasurementQualityError.invalidThresholds("RMS thresholds must be positive and strictly increasing.")
        }
        guard (0...1).contains(minimumUsableCorrelation),
              minimumUsableCorrelation < goodCorrelation,
              goodCorrelation < excellentCorrelation,
              excellentCorrelation <= 1 else {
            throw MeasurementQualityError.invalidThresholds("Correlation thresholds must increase within zero through one.")
        }
        guard questionablePrimaryToSecondaryRatio >= 1,
              questionablePrimaryToSecondaryRatio < goodPrimaryToSecondaryRatio,
              goodPrimaryToSecondaryRatio < excellentPrimaryToSecondaryRatio,
              questionablePeakToSidelobeRatio > 0,
              questionablePeakToSidelobeRatio < goodPeakToSidelobeRatio,
              goodPeakToSidelobeRatio < excellentPeakToSidelobeRatio else {
            throw MeasurementQualityError.invalidThresholds("Peak-ratio thresholds must be positive and strictly increasing.")
        }
        guard poorSignalToNoiseDecibels < goodSignalToNoiseDecibels,
              goodSignalToNoiseDecibels < excellentSignalToNoiseDecibels,
              finiteSNRLimitDecibels > abs(poorSignalToNoiseDecibels),
              finiteSNRLimitDecibels > excellentSignalToNoiseDecibels else {
            throw MeasurementQualityError.invalidThresholds("SNR thresholds and finite limit are inconsistent.")
        }
        guard clippingWarningRatio >= 0,
              clippingWarningRatio < clippingSevereRatio,
              clippingSevereRatio <= 1,
              dcOffsetWarningMagnitude >= 0,
              dcOffsetWarningMagnitude < dcOffsetSevereMagnitude else {
            throw MeasurementQualityError.invalidThresholds("Clipping and DC thresholds must be nonnegative and increasing.")
        }
        guard coverageSevereRatio >= 0,
              coverageSevereRatio < coverageWarningRatio,
              coverageWarningRatio <= 1,
              goodPeakWidthSamples > 0,
              goodPeakWidthSamples < poorPeakWidthSamples,
              goodLocalSharpness > 0,
              goodLocalSharpness < excellentLocalSharpness,
              excellentLocalSharpness <= 1 else {
            throw MeasurementQualityError.invalidThresholds("Coverage and peak-shape thresholds are inconsistent.")
        }
        guard searchBoundaryWarningSamples >= 0,
              searchBoundaryWarningSamples < searchBoundaryGoodSamples,
              channelDelayWarningSamples >= 0,
              channelDelayWarningSamples < channelDelaySevereSamples,
              channelPeakWarningDifference >= 0,
              channelPeakWarningDifference < channelPeakSevereDifference else {
            throw MeasurementQualityError.invalidThresholds("Boundary and channel thresholds are inconsistent.")
        }
        guard (0...1).contains(candidateMinimumRelativeMagnitude),
              (0...1).contains(repeatedPeakRelativeMagnitude),
              (0...1).contains(ambiguousPeakRelativeMagnitude),
              candidateMinimumRelativeMagnitude < repeatedPeakRelativeMagnitude,
              repeatedPeakRelativeMagnitude < ambiguousPeakRelativeMagnitude,
              maximumPeakCandidates >= 2,
              candidateExclusionRadius >= 0,
              candidateExclusionRadius <= Int64(Int.max),
              periodicSpacingToleranceRatio >= 0,
              periodicSpacingToleranceSamples >= 0 else {
            throw MeasurementQualityError.invalidThresholds("Peak-candidate policy is invalid.")
        }
        guard questionableScoreMinimum > 0,
              questionableScoreMinimum < goodScoreMinimum,
              goodScoreMinimum < excellentScoreMinimum,
              excellentScoreMinimum <= 1,
              (0...1).contains(goodMetricNormalizedScore),
              (0...1).contains(errorScoreCap),
              (0...1).contains(uncertaintyScoreCap),
              (0...1).contains(warningScoreCap),
              errorScoreCap < uncertaintyScoreCap,
              uncertaintyScoreCap < warningScoreCap,
              errorScoreCap < questionableScoreMinimum,
              uncertaintyScoreCap < goodScoreMinimum,
              warningScoreCap < excellentScoreMinimum else {
            throw MeasurementQualityError.invalidThresholds("Score levels, normalized node, and issue caps are inconsistent.")
        }
        let weightValues = [
            weights.primaryCorrelation, weights.primaryToSecondaryRatio,
            weights.peakToSidelobeRatio, weights.peakWidth,
            weights.localSharpness, weights.inputLevel, weights.signalToNoise,
            weights.clipping, weights.dcOffset, weights.referenceCoverage,
            weights.searchBoundary, weights.channelAgreement
        ]
        guard weightValues.allSatisfy({ $0.isFinite && $0 >= 0 }),
              weightValues.reduce(0, +) > 0 else {
            throw MeasurementQualityError.invalidThresholds("Metric weights must be finite, nonnegative, and not all zero.")
        }
    }
}
