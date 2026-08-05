import AudioLinkCore
import Foundation

/// Converts quality diagnostics into UI-ready value types without importing
/// SwiftUI or choosing a concrete visual presentation.
public struct MeasurementQualityFormatter: Sendable {
    public init() {}

    public func presentation(for quality: MeasurementQuality) -> MeasurementQualityPresentation {
        let preferredMetrics: [QualityMetricCode] = [
            .primaryCorrelation,
            .primaryToSecondaryRatio,
            .peakToSidelobeRatio,
            .signalToNoiseDecibels,
            .peakWidthSamples,
            .observedRMS,
            .clippingRatio,
            .referenceCoverageRatio,
            .searchBoundaryDistanceSamples,
            .channelDelaySpreadSamples
        ]
        let byCode = Dictionary(uniqueKeysWithValues: quality.metrics.map { ($0.code, $0) })
        let metrics = preferredMetrics.compactMap { code -> QualityMetricPresentation? in
            guard let metric = byCode[code] else { return nil }
            return QualityMetricPresentation(
                code: code,
                title: metricTitle(code),
                formattedValue: formattedValue(metric),
                explanation: metric.explanation
            )
        }
        let issuePresentations = quality.issues.map { issue in
            QualityIssuePresentation(
                code: issue.code,
                severity: issue.severity,
                title: issueTitle(issue.code),
                detail: issue.userDescription,
                recommendation: issue.recommendedAction
            )
        }
        var seenRecommendations: Set<String> = []
        let recommendations = quality.issues.compactMap { issue -> String? in
            guard seenRecommendations.insert(issue.recommendedAction).inserted else { return nil }
            return issue.recommendedAction
        }
        return MeasurementQualityPresentation(
            level: quality.level,
            title: levelTitle(quality.level),
            summary: quality.summary,
            scoreText: String(format: "%.0f%%", quality.confidence.percentage),
            keyMetrics: metrics,
            warnings: issuePresentations,
            recommendations: recommendations,
            acousticWarnings: quality.acousticDiagnostics?.issues.map { "\($0.statement) Evidence: \($0.evidence)" } ?? [],
            shouldRemeasure: quality.shouldRemeasure
        )
    }

    private func levelTitle(_ level: MeasurementQualityLevel) -> String {
        switch level {
        case .excellent: "Excellent measurement"
        case .good: "Good measurement"
        case .questionable: "Questionable measurement"
        case .poor: "Poor measurement"
        case .invalid: "Invalid measurement"
        }
    }

    private func metricTitle(_ code: QualityMetricCode) -> String {
        switch code {
        case .primaryCorrelation: "Correlation peak"
        case .primaryToSecondaryRatio: "Peak separation"
        case .peakToSidelobeRatio: "Peak-to-sidelobe ratio"
        case .peakWidthSamples: "Peak width"
        case .localPeakSharpness: "Peak sharpness"
        case .referenceRMS: "Reference RMS"
        case .observedRMS: "Recording RMS"
        case .signalToNoiseDecibels: "Estimated SNR"
        case .clippingRatio: "Clipping"
        case .dcOffsetMagnitude: "DC offset"
        case .referenceCoverageRatio: "Reference coverage"
        case .searchBoundaryDistanceSamples: "Search-boundary distance"
        case .invertedPolarity: "Polarity inverted"
        case .similarPeakCount: "Similar peaks"
        case .truncationRatio: "Missing reference"
        case .channelDelaySpreadSamples: "Channel delay spread"
        case .channelPeakSpread: "Channel peak spread"
        }
    }

    private func issueTitle(_ code: QualityIssueCode) -> String {
        switch code {
        case .inputTooQuiet: "Input too quiet"
        case .clippingDetected: "Clipping detected"
        case .ambiguousPeak: "Ambiguous delay peak"
        case .peakAtSearchBoundary: "Peak near search boundary"
        case .sampleRateConverted: "Sample rate converted"
        case .polarityInverted: "Polarity inverted"
        case .referencePartiallyMissing: "Reference partially missing"
        case .excessiveNoise: "Excessive noise"
        case .channelsDisagree: "Channels disagree"
        case .dcOffsetDetected: "DC offset detected"
        case .broadCorrelationPeak: "Broad correlation peak"
        case .weakCorrelationPeak: "Weak correlation peak"
        case .lowPeakSeparation: "Low peak separation"
        case .periodicPeakPattern: "Periodic peak pattern"
        case .possibleTruncation: "Possible truncation"
        case .searchRangeClamped: "Search range clamped"
        case .analysisUnavailable: "Analysis unavailable"
        }
    }

    private func formattedValue(_ metric: QualityMetric) -> String {
        if metric.value == Double.greatestFiniteMagnitude { return "∞" }
        switch metric.unit {
        case .coefficient, .ratio, .normalizedAmplitude:
            return String(format: "%.3f", metric.value)
        case .samples:
            return String(format: "%.2f samples", metric.value)
        case .decibels:
            return String(format: "%.1f dB", metric.value)
        case .fraction:
            return String(format: "%.2f%%", metric.value * 100)
        case .boolean:
            return metric.value == 0 ? "No" : "Yes"
        case .count:
            return String(format: "%.0f", metric.value)
        }
    }
}
