import Foundation
import AudioLinkCore

/// One known event observed in a recording. Positions are expressed in samples
/// in the same clock domain as the reference signal.
public struct DriftObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let eventIndex: Int
    public let expectedSamplePosition: Double
    public let observedSamplePosition: Double
    public let confidence: Double
    public let timestampSeconds: Double?

    public init(
        id: UUID = UUID(),
        eventIndex: Int,
        expectedSamplePosition: Double,
        observedSamplePosition: Double,
        confidence: Double = 1,
        timestampSeconds: Double? = nil
    ) {
        self.id = id
        self.eventIndex = eventIndex
        self.expectedSamplePosition = expectedSamplePosition
        self.observedSamplePosition = observedSamplePosition
        self.confidence = confidence
        self.timestampSeconds = timestampSeconds
    }
}

public struct LinearFitDiagnostics: Codable, Equatable, Sendable {
    public let slope: Double
    public let intercept: Double
    public let rSquared: Double
    public let residuals: [Double]
    public let residualRMSSamples: Double
    public let maximumAbsoluteResidualSamples: Double

    public init(
        slope: Double,
        intercept: Double,
        rSquared: Double,
        residuals: [Double],
        residualRMSSamples: Double,
        maximumAbsoluteResidualSamples: Double
    ) {
        self.slope = slope
        self.intercept = intercept
        self.rSquared = rSquared
        self.residuals = residuals
        self.residualRMSSamples = residualRMSSamples
        self.maximumAbsoluteResidualSamples = maximumAbsoluteResidualSamples
    }
}

public struct DriftEstimate: Codable, Equatable, Sendable {
    public let observations: [DriftObservation]
    public let constantOffsetSamples: Double
    public let driftPPM: Double
    public let fit: LinearFitDiagnostics
    public let confidence: Double
    public let outlierEventIndices: [Int]
    public let nonlinearWarning: String?
    public let isValid: Bool

    public init(
        observations: [DriftObservation],
        constantOffsetSamples: Double,
        driftPPM: Double,
        fit: LinearFitDiagnostics,
        confidence: Double,
        outlierEventIndices: [Int] = [],
        nonlinearWarning: String? = nil,
        isValid: Bool = true
    ) {
        self.observations = observations
        self.constantOffsetSamples = constantOffsetSamples
        self.driftPPM = driftPPM
        self.fit = fit
        self.confidence = confidence
        self.outlierEventIndices = outlierEventIndices
        self.nonlinearWarning = nonlinearWarning
        self.isValid = isValid
    }
}

public struct ClockDriftEstimationConfiguration: Codable, Equatable, Sendable {
    public let minimumObservations: Int
    public let rejectOutliers: Bool
    public let outlierResidualThresholdSamples: Double
    public let nonlinearSlopeDifferencePPMThreshold: Double

    public init(
        minimumObservations: Int = 3,
        rejectOutliers: Bool = true,
        outlierResidualThresholdSamples: Double = 3,
        nonlinearSlopeDifferencePPMThreshold: Double = 10
    ) {
        self.minimumObservations = minimumObservations
        self.rejectOutliers = rejectOutliers
        self.outlierResidualThresholdSamples = outlierResidualThresholdSamples
        self.nonlinearSlopeDifferencePPMThreshold = nonlinearSlopeDifferencePPMThreshold
    }
}

public enum ClockDriftError: Error, LocalizedError, Equatable, Sendable {
    case insufficientObservations(required: Int, actual: Int)
    case nonFiniteObservation(index: Int)
    case duplicateExpectedPositions
    case invalidConfiguration

    public var errorDescription: String? {
        switch self {
        case let .insufficientObservations(required, actual):
            "At least \(required) valid events are required to estimate clock drift (received \(actual))."
        case let .nonFiniteObservation(index):
            "Event \(index) contains a non-finite sample position."
        case .duplicateExpectedPositions:
            "Clock-drift events must have distinct expected positions."
        case .invalidConfiguration:
            "The clock-drift estimation configuration is invalid."
        }
    }
}

public struct ClockDriftEstimator: Sendable {
    public init() {}

    public func estimate(
        observations: [DriftObservation],
        configuration: ClockDriftEstimationConfiguration = .init()
    ) throws -> DriftEstimate {
        guard configuration.minimumObservations >= 2,
              configuration.outlierResidualThresholdSamples > 0,
              configuration.nonlinearSlopeDifferencePPMThreshold >= 0 else {
            throw ClockDriftError.invalidConfiguration
        }
        let sorted = observations.sorted { $0.expectedSamplePosition < $1.expectedSamplePosition }
        guard sorted.count >= configuration.minimumObservations else {
            throw ClockDriftError.insufficientObservations(required: configuration.minimumObservations, actual: sorted.count)
        }
        for (index, observation) in sorted.enumerated() {
            guard observation.expectedSamplePosition.isFinite,
                  observation.observedSamplePosition.isFinite,
                  observation.confidence.isFinite else {
                throw ClockDriftError.nonFiniteObservation(index: index)
            }
            if index > 0, observation.expectedSamplePosition == sorted[index - 1].expectedSamplePosition {
                throw ClockDriftError.duplicateExpectedPositions
            }
        }

        var active = Array(sorted.indices)
        var fit = linearFit(sorted, indices: active)
        var outlierIndices: [Int] = []
        if configuration.rejectOutliers {
            let residualCenter = fit.residuals.sorted()[fit.residuals.count / 2]
            let residualDeviations = fit.residuals.map { abs($0 - residualCenter) }.sorted()
            let residualMAD = residualDeviations[residualDeviations.count / 2] * 1.4826
            let robustCutoff = max(configuration.outlierResidualThresholdSamples, configuration.outlierResidualThresholdSamples * residualMAD)
            outlierIndices = active.filter {
                abs(fit.residuals[$0] - residualCenter) > robustCutoff
            }.map { sorted[$0].eventIndex }
            if sorted.count - outlierIndices.count >= configuration.minimumObservations {
                active = active.filter { !outlierIndices.contains(sorted[$0].eventIndex) }
                fit = linearFit(sorted, indices: active)
            } else {
                outlierIndices = []
            }
        }

        let slope = fit.slope
        let driftPPM = (slope - 1) * 1_000_000
        let confidence = max(0, min(1, fit.rSquared * min(1, Double(active.count) / 10)))
        let warning = nonlinearWarning(sorted: sorted, indices: active, thresholdPPM: configuration.nonlinearSlopeDifferencePPMThreshold)
        return DriftEstimate(
            observations: sorted,
            constantOffsetSamples: fit.intercept,
            driftPPM: driftPPM,
            fit: fit,
            confidence: confidence,
            outlierEventIndices: outlierIndices.sorted(),
            nonlinearWarning: warning,
            isValid: active.count >= configuration.minimumObservations
        )
    }

    private func linearFit(_ observations: [DriftObservation], indices: [Int]) -> LinearFitDiagnostics {
        let x = indices.map { observations[$0].expectedSamplePosition }
        let y = indices.map { observations[$0].observedSamplePosition }
        let meanX = x.reduce(0, +) / Double(x.count)
        let meanY = y.reduce(0, +) / Double(y.count)
        let denominator = x.reduce(0) { $0 + pow($1 - meanX, 2) }
        let numerator = zip(x, y).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let slope = denominator > 0 ? numerator / denominator : 1
        let intercept = meanY - slope * meanX
        let residuals = observations.map { $0.observedSamplePosition - (slope * $0.expectedSamplePosition + intercept) }
        let activeResiduals = indices.map { residuals[$0] }
        let ssResidual = activeResiduals.reduce(0) { $0 + $1 * $1 }
        let ssTotal = y.reduce(0) { $0 + pow($1 - meanY, 2) }
        let rSquared = ssTotal > 0 ? max(0, min(1, 1 - ssResidual / ssTotal)) : (ssResidual == 0 ? 1 : 0)
        return LinearFitDiagnostics(
            slope: slope,
            intercept: intercept,
            rSquared: rSquared,
            residuals: residuals,
            residualRMSSamples: sqrt(ssResidual / Double(max(1, activeResiduals.count))),
            maximumAbsoluteResidualSamples: activeResiduals.map { abs($0) }.max() ?? 0
        )
    }

    private func nonlinearWarning(
        sorted: [DriftObservation],
        indices: [Int],
        thresholdPPM: Double
    ) -> String? {
        guard indices.count >= 4 else { return nil }
        let midpoint = indices.count / 2
        let first = linearFit(sorted, indices: Array(indices[..<midpoint]))
        let second = linearFit(sorted, indices: Array(indices[midpoint...]))
        let differencePPM = abs(first.slope - second.slope) * 1_000_000
        guard differencePPM > thresholdPPM else { return nil }
        return "Possible non-linear clock drift: early and late fitted slopes differ by \(differencePPM.formatted(.number.precision(.fractionLength(1)))) ppm."
    }
}
