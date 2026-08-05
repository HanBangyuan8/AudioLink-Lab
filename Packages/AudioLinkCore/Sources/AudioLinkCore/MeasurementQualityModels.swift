import Foundation

public enum MeasurementQualityLevel: String, Codable, CaseIterable, Sendable {
    case excellent
    case good
    case questionable
    case poor
    case invalid
}

public enum QualityIssueSeverity: String, Codable, CaseIterable, Sendable {
    case information
    case warning
    case error
    case fatal
}

public enum QualityIssueCode: String, Codable, CaseIterable, Sendable {
    case inputTooQuiet
    case clippingDetected
    case ambiguousPeak
    case peakAtSearchBoundary
    case sampleRateConverted
    case polarityInverted
    case referencePartiallyMissing
    case excessiveNoise
    case channelsDisagree
    case dcOffsetDetected
    case broadCorrelationPeak
    case weakCorrelationPeak
    case lowPeakSeparation
    case periodicPeakPattern
    case possibleTruncation
    case searchRangeClamped
    case analysisUnavailable
}

public struct QualityIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: QualityIssueCode { code }
    public let code: QualityIssueCode
    public let severity: QualityIssueSeverity
    public let userDescription: String
    public let technicalDescription: String
    public let recommendedAction: String

    public init(
        code: QualityIssueCode,
        severity: QualityIssueSeverity,
        userDescription: String,
        technicalDescription: String,
        recommendedAction: String
    ) {
        self.code = code
        self.severity = severity
        self.userDescription = userDescription
        self.technicalDescription = technicalDescription
        self.recommendedAction = recommendedAction
    }
}

public enum QualityMetricCode: String, Codable, CaseIterable, Sendable {
    case primaryCorrelation
    case primaryToSecondaryRatio
    case peakToSidelobeRatio
    case peakWidthSamples
    case localPeakSharpness
    case referenceRMS
    case observedRMS
    case signalToNoiseDecibels
    case clippingRatio
    case dcOffsetMagnitude
    case referenceCoverageRatio
    case searchBoundaryDistanceSamples
    case invertedPolarity
    case similarPeakCount
    case truncationRatio
    case channelDelaySpreadSamples
    case channelPeakSpread
}

public enum QualityMetricUnit: String, Codable, CaseIterable, Sendable {
    case coefficient
    case ratio
    case samples
    case decibels
    case fraction
    case normalizedAmplitude
    case boolean
    case count
}

public struct QualityMetric: Codable, Equatable, Sendable, Identifiable {
    public var id: QualityMetricCode { code }
    public let code: QualityMetricCode
    public let value: Double
    public let unit: QualityMetricUnit
    /// A deterministic 0...1 interpretation under the active threshold set.
    public let normalizedScore: Double
    public let weight: Double
    public let idealMinimum: Double?
    public let idealMaximum: Double?
    public let explanation: String

    public init(
        code: QualityMetricCode,
        value: Double,
        unit: QualityMetricUnit,
        normalizedScore: Double,
        weight: Double,
        idealMinimum: Double? = nil,
        idealMaximum: Double? = nil,
        explanation: String
    ) {
        self.code = code
        self.value = value
        self.unit = unit
        self.normalizedScore = normalizedScore
        self.weight = weight
        self.idealMinimum = idealMinimum
        self.idealMaximum = idealMaximum
        self.explanation = explanation
    }
}

public struct ConfidenceComponent: Codable, Equatable, Sendable, Identifiable {
    public var id: QualityMetricCode { metric }
    public let metric: QualityMetricCode
    public let normalizedScore: Double
    public let weight: Double
    public let weightedContribution: Double

    public init(
        metric: QualityMetricCode,
        normalizedScore: Double,
        weight: Double,
        weightedContribution: Double
    ) {
        self.metric = metric
        self.normalizedScore = normalizedScore
        self.weight = weight
        self.weightedContribution = weightedContribution
    }
}

public struct ConfidenceScore: Codable, Equatable, Sendable {
    /// Normalized 0...1 aggregate. The component list is the explanation.
    public let value: Double
    public let components: [ConfidenceComponent]

    public init(value: Double, components: [ConfidenceComponent]) {
        self.value = value
        self.components = components
    }

    public var percentage: Double { value * 100 }
}

public struct PeakAmbiguity: Codable, Equatable, Sendable {
    public let candidates: [CorrelationPeak]
    public let primaryToSecondaryRatio: Double?
    public let hasSimilarPeaks: Bool
    public let peakSpacings: [SampleCount]
    public let periodicInterval: SampleCount?
    public let explanation: String

    public init(
        candidates: [CorrelationPeak],
        primaryToSecondaryRatio: Double?,
        hasSimilarPeaks: Bool,
        peakSpacings: [SampleCount],
        periodicInterval: SampleCount?,
        explanation: String
    ) {
        self.candidates = candidates
        self.primaryToSecondaryRatio = primaryToSecondaryRatio
        self.hasSimilarPeaks = hasSimilarPeaks
        self.peakSpacings = peakSpacings
        self.periodicInterval = periodicInterval
        self.explanation = explanation
    }
}

public struct ChannelDelayDiagnostic: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { channel }
    public let channel: Int
    public let delay: DelayEstimate?
    public let normalizedPeak: Double?
    public let validity: DelayAnalysisValidity?

    public init(
        channel: Int,
        delay: DelayEstimate?,
        normalizedPeak: Double?,
        validity: DelayAnalysisValidity?
    ) {
        self.channel = channel
        self.delay = delay
        self.normalizedPeak = normalizedPeak
        self.validity = validity
    }
}

public struct SignalQualityAnalysis: Codable, Equatable, Sendable {
    public let referenceRMS: Double
    public let observedRMS: Double
    public let signalToNoiseDecibels: Double?
    public let clippingRatio: Double
    public let dcOffsetMagnitude: Double
    public let referenceCoverageRatio: Double?
    public let isPolarityInverted: Bool?
    public let appearsTruncated: Bool
    public let channelsConsistent: Bool?
    public let channelDelaySpreadSamples: Double?
    public let channelPeakSpread: Double?

    public init(
        referenceRMS: Double,
        observedRMS: Double,
        signalToNoiseDecibels: Double?,
        clippingRatio: Double,
        dcOffsetMagnitude: Double,
        referenceCoverageRatio: Double?,
        isPolarityInverted: Bool?,
        appearsTruncated: Bool,
        channelsConsistent: Bool?,
        channelDelaySpreadSamples: Double?,
        channelPeakSpread: Double?
    ) {
        self.referenceRMS = referenceRMS
        self.observedRMS = observedRMS
        self.signalToNoiseDecibels = signalToNoiseDecibels
        self.clippingRatio = clippingRatio
        self.dcOffsetMagnitude = dcOffsetMagnitude
        self.referenceCoverageRatio = referenceCoverageRatio
        self.isPolarityInverted = isPolarityInverted
        self.appearsTruncated = appearsTruncated
        self.channelsConsistent = channelsConsistent
        self.channelDelaySpreadSamples = channelDelaySpreadSamples
        self.channelPeakSpread = channelPeakSpread
    }
}

public struct DelayEstimateDiagnostics: Codable, Equatable, Sendable {
    public let selectedDelay: DelayEstimate?
    public let candidatePeaks: [CorrelationPeak]
    public let peakWidthSamples: Double?
    public let localPeakSharpness: Double?
    public let searchBoundaryDistance: SampleCount?
    public let channelResults: [ChannelDelayDiagnostic]

    public init(
        selectedDelay: DelayEstimate?,
        candidatePeaks: [CorrelationPeak],
        peakWidthSamples: Double?,
        localPeakSharpness: Double?,
        searchBoundaryDistance: SampleCount?,
        channelResults: [ChannelDelayDiagnostic]
    ) {
        self.selectedDelay = selectedDelay
        self.candidatePeaks = candidatePeaks
        self.peakWidthSamples = peakWidthSamples
        self.localPeakSharpness = localPeakSharpness
        self.searchBoundaryDistance = searchBoundaryDistance
        self.channelResults = channelResults
    }
}

/// Heuristic observations about the acoustic path. These are deliberately
/// phrased as possibilities rather than claims about the physical room.
public enum AcousticDiagnosticCode: String, Codable, CaseIterable, Sendable {
    case clippingDetected
    case lowInputLevel
    case highNoiseFloor
    case possibleReverberation
    case multipleEchoes
    case earlyReflectionCandidate
    case channelImbalance
    case polarityInversion
    case partialSignalCapture
}

public struct EarlyReflectionCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { lagSamples }
    public let lagSamples: Int
    public let delayMilliseconds: Double
    public let relativeMagnitude: Double
    public let evidence: String

    public init(lagSamples: Int, delayMilliseconds: Double, relativeMagnitude: Double, evidence: String) {
        self.lagSamples = lagSamples
        self.delayMilliseconds = delayMilliseconds
        self.relativeMagnitude = relativeMagnitude
        self.evidence = evidence
    }
}

public struct AcousticPathDiagnosticMetrics: Codable, Equatable, Sendable {
    public let inputRMS: Double
    public let noiseFloorRMS: Double
    public let estimatedSignalToNoiseDecibels: Double?
    public let clippingRatio: Double
    public let reverberationRatio: Double
    public let channelRMSSpreadDecibels: Double?
    public let referenceCoverageRatio: Double?
    public let primaryPeakSignedAmplitude: Double?

    public init(
        inputRMS: Double,
        noiseFloorRMS: Double,
        estimatedSignalToNoiseDecibels: Double?,
        clippingRatio: Double,
        reverberationRatio: Double,
        channelRMSSpreadDecibels: Double?,
        referenceCoverageRatio: Double?,
        primaryPeakSignedAmplitude: Double?
    ) {
        self.inputRMS = inputRMS
        self.noiseFloorRMS = noiseFloorRMS
        self.estimatedSignalToNoiseDecibels = estimatedSignalToNoiseDecibels
        self.clippingRatio = clippingRatio
        self.reverberationRatio = reverberationRatio
        self.channelRMSSpreadDecibels = channelRMSSpreadDecibels
        self.referenceCoverageRatio = referenceCoverageRatio
        self.primaryPeakSignedAmplitude = primaryPeakSignedAmplitude
    }
}

public struct AcousticDiagnosticIssue: Codable, Equatable, Identifiable, Sendable {
    public let id: AcousticDiagnosticCode
    public let code: AcousticDiagnosticCode
    public let severity: QualityIssueSeverity
    public let statement: String
    public let evidence: String
    public let recommendation: String

    public init(
        code: AcousticDiagnosticCode,
        severity: QualityIssueSeverity,
        statement: String,
        evidence: String,
        recommendation: String
    ) {
        self.id = code
        self.code = code
        self.severity = severity
        self.statement = statement
        self.evidence = evidence
        self.recommendation = recommendation
    }
}

public struct AcousticPathDiagnostics: Codable, Equatable, Sendable {
    public let metrics: AcousticPathDiagnosticMetrics
    public let issues: [AcousticDiagnosticIssue]
    public let earlyReflections: [EarlyReflectionCandidate]
    public let evidenceSummary: String

    public init(
        metrics: AcousticPathDiagnosticMetrics,
        issues: [AcousticDiagnosticIssue],
        earlyReflections: [EarlyReflectionCandidate],
        evidenceSummary: String
    ) {
        self.metrics = metrics
        self.issues = issues
        self.earlyReflections = earlyReflections
        self.evidenceSummary = evidenceSummary
    }
}

public struct MeasurementQuality: Codable, Equatable, Sendable {
    public let level: MeasurementQualityLevel
    public let confidence: ConfidenceScore
    public let summary: String
    public let metrics: [QualityMetric]
    public let issues: [QualityIssue]
    public let peakAmbiguity: PeakAmbiguity
    public let signal: SignalQualityAnalysis
    public let delayDiagnostics: DelayEstimateDiagnostics
    public let acousticDiagnostics: AcousticPathDiagnostics?
    public let shouldRemeasure: Bool

    public init(
        level: MeasurementQualityLevel,
        confidence: ConfidenceScore,
        summary: String,
        metrics: [QualityMetric],
        issues: [QualityIssue],
        peakAmbiguity: PeakAmbiguity,
        signal: SignalQualityAnalysis,
        delayDiagnostics: DelayEstimateDiagnostics,
        acousticDiagnostics: AcousticPathDiagnostics? = nil,
        shouldRemeasure: Bool
    ) {
        self.level = level
        self.confidence = confidence
        self.summary = summary
        self.metrics = metrics
        self.issues = issues
        self.peakAmbiguity = peakAmbiguity
        self.signal = signal
        self.delayDiagnostics = delayDiagnostics
        self.acousticDiagnostics = acousticDiagnostics
        self.shouldRemeasure = shouldRemeasure
    }
}

public struct QualityAssessedMeasurement: Codable, Equatable, Sendable {
    /// Nil for invalid/no-signal measurements so consumers cannot present a
    /// random correlation maximum as a precise latency.
    public let delay: DelayEstimate?
    public let correlation: CorrelationResult?
    public let quality: MeasurementQuality
    public let calibration: CalibratedDelayResult?

    public init(
        delay: DelayEstimate?,
        correlation: CorrelationResult?,
        quality: MeasurementQuality,
        calibration: CalibratedDelayResult? = nil
    ) {
        self.delay = delay
        self.correlation = correlation
        self.quality = quality
        self.calibration = calibration
    }

    public func withCalibration(_ calibration: CalibratedDelayResult?) -> Self {
        Self(delay: delay, correlation: correlation, quality: quality, calibration: calibration)
    }
}

public struct QualityMetricPresentation: Codable, Equatable, Sendable, Identifiable {
    public var id: QualityMetricCode { code }
    public let code: QualityMetricCode
    public let title: String
    public let formattedValue: String
    public let explanation: String

    public init(code: QualityMetricCode, title: String, formattedValue: String, explanation: String) {
        self.code = code
        self.title = title
        self.formattedValue = formattedValue
        self.explanation = explanation
    }
}

public struct QualityIssuePresentation: Codable, Equatable, Sendable, Identifiable {
    public var id: QualityIssueCode { code }
    public let code: QualityIssueCode
    public let severity: QualityIssueSeverity
    public let title: String
    public let detail: String
    public let recommendation: String

    public init(
        code: QualityIssueCode,
        severity: QualityIssueSeverity,
        title: String,
        detail: String,
        recommendation: String
    ) {
        self.code = code
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
    }
}

public struct MeasurementQualityPresentation: Codable, Equatable, Sendable {
    public let level: MeasurementQualityLevel
    public let title: String
    public let summary: String
    public let scoreText: String
    public let keyMetrics: [QualityMetricPresentation]
    public let warnings: [QualityIssuePresentation]
    public let recommendations: [String]
    public let acousticWarnings: [String]
    public let shouldRemeasure: Bool

    public init(
        level: MeasurementQualityLevel,
        title: String,
        summary: String,
        scoreText: String,
        keyMetrics: [QualityMetricPresentation],
        warnings: [QualityIssuePresentation],
        recommendations: [String],
        acousticWarnings: [String] = [],
        shouldRemeasure: Bool
    ) {
        self.level = level
        self.title = title
        self.summary = summary
        self.scoreText = scoreText
        self.keyMetrics = keyMetrics
        self.warnings = warnings
        self.recommendations = recommendations
        self.acousticWarnings = acousticWarnings
        self.shouldRemeasure = shouldRemeasure
    }
}
