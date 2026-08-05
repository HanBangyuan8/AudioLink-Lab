import AudioLinkCore
import Foundation

public struct MeasurementQualityAnalyzer: Sendable {
    private let delayEngine: DelayAnalysisEngine

    public init(delayEngine: DelayAnalysisEngine = .init()) {
        self.delayEngine = delayEngine
    }

    public func analyze(
        reference: ImportedAudioFile,
        observed: ImportedAudioFile,
        correlationConfiguration: CorrelationConfiguration = .init(),
        thresholds: MeasurementQualityThresholds = .standard
    ) async throws -> QualityAssessedMeasurement {
        try thresholds.validate()
        guard reference.sampleRate == observed.sampleRate else {
            throw CorrelationAnalysisError.sampleRateMismatch(
                reference: reference.sampleRate,
                observed: observed.sampleRate
            )
        }
        guard reference.channelCount == observed.channelCount else {
            throw CorrelationAnalysisError.channelCountMismatch(
                reference: reference.channelCount,
                observed: observed.channelCount
            )
        }
        guard (0..<reference.channelCount).contains(correlationConfiguration.channel) else {
            throw CorrelationAnalysisError.invalidChannel(
                requested: correlationConfiguration.channel,
                available: reference.channelCount
            )
        }

        let selectedChannel = correlationConfiguration.channel
        let referenceSamples = try channelSamples(reference.audio, channel: selectedChannel)
        let observedSamples = try channelSamples(observed.audio, channel: selectedChannel)
        let referenceRMS = try rootMeanSquare(referenceSamples)
        let observedRMS = try rootMeanSquare(observedSamples)
        let clippingRatio = observed.audio.samples.isEmpty
            ? 0
            : Double(observed.clippingSampleCount) / Double(observed.audio.samples.count)
        let dcOffsetMagnitude = observed.analysis.channelDCOffsets.map { abs(Double($0)) }.max() ?? 0

        if referenceRMS < thresholds.invalidInputRMS || observedRMS < thresholds.invalidInputRMS {
            return invalidInputMeasurement(
                referenceRMS: referenceRMS,
                observedRMS: observedRMS,
                clippingRatio: clippingRatio,
                dcOffsetMagnitude: dcOffsetMagnitude,
                reference: reference,
                observed: observed,
                thresholds: thresholds
            )
        }

        var channelResults: [(channel: Int, result: DelayAnalysisResult?)] = []
        channelResults.reserveCapacity(reference.channelCount)
        for channel in 0..<reference.channelCount {
            try checkCancellation()
            var configuration = correlationConfiguration
            configuration.channel = channel
            configuration.sequenceOutput = channel == selectedChannel ? .searchedRange : .none
            do {
                let result = try await delayEngine.analyze(
                    reference: reference.audio,
                    observed: observed.audio,
                    configuration: configuration
                )
                channelResults.append((channel, result))
            } catch let error as CorrelationAnalysisError {
                switch error {
                case .insufficientReferenceSignal, .insufficientObservedSignal:
                    channelResults.append((channel, nil))
                default:
                    throw error
                }
            }
        }

        guard let selectedResult = channelResults.first(where: { $0.channel == selectedChannel })?.result else {
            return invalidInputMeasurement(
                referenceRMS: referenceRMS,
                observedRMS: observedRMS,
                clippingRatio: clippingRatio,
                dcOffsetMagnitude: dcOffsetMagnitude,
                reference: reference,
                observed: observed,
                thresholds: thresholds
            )
        }
        guard let sequence = selectedResult.correlation.sequence,
              let primaryPeak = selectedResult.correlation.primaryPeak,
              let correlationDiagnostics = selectedResult.correlation.diagnostics else {
            return unavailableMeasurement(
                referenceRMS: referenceRMS,
                observedRMS: observedRMS,
                clippingRatio: clippingRatio,
                dcOffsetMagnitude: dcOffsetMagnitude,
                selectedDelay: selectedResult.delay
            )
        }

        let shape = try analyzePeakShape(
            sequence: sequence,
            primaryPeak: primaryPeak,
            referenceCount: reference.frameCount,
            observedCount: observed.frameCount,
            thresholds: thresholds
        )
        let coverage = reference.frameCount > 0
            ? min(1, Double(primaryPeak.overlapCount.rawValue) / Double(reference.frameCount))
            : 0
        let boundaryDistance = max(
            0,
            min(
                primaryPeak.lag.rawValue - correlationDiagnostics.searchedLagRange.minimum,
                correlationDiagnostics.searchedLagRange.maximum - primaryPeak.lag.rawValue
            )
        )
        let snr = try signalToNoiseEstimate(
            reference: referenceSamples,
            observed: observedSamples,
            lag: primaryPeak.lag.rawValue,
            finiteLimit: thresholds.finiteSNRLimitDecibels
        )
        let channelDiagnostics = channelResults.map { item in
            ChannelDelayDiagnostic(
                channel: item.channel,
                delay: item.result?.delay,
                normalizedPeak: item.result?.correlation.normalizedPeak,
                validity: item.result?.correlation.diagnostics?.validity
            )
        }
        let channelAgreement = analyzeChannelAgreement(
            channelResults,
            thresholds: thresholds
        )
        let appearsTruncated = coverage < thresholds.coverageSevereRatio

        let signalAnalysis = SignalQualityAnalysis(
            referenceRMS: referenceRMS,
            observedRMS: observedRMS,
            signalToNoiseDecibels: snr,
            clippingRatio: clippingRatio,
            dcOffsetMagnitude: dcOffsetMagnitude,
            referenceCoverageRatio: coverage,
            isPolarityInverted: primaryPeak.value < 0,
            appearsTruncated: appearsTruncated,
            channelsConsistent: channelAgreement.consistent,
            channelDelaySpreadSamples: channelAgreement.delaySpread,
            channelPeakSpread: channelAgreement.peakSpread
        )
        let ambiguity = PeakAmbiguity(
            candidates: shape.candidates,
            primaryToSecondaryRatio: shape.primaryToSecondaryRatio,
            hasSimilarPeaks: shape.hasSimilarPeaks,
            peakSpacings: shape.peakSpacings.map { SampleCount(rawValue: $0) },
            periodicInterval: shape.periodicInterval.map { SampleCount(rawValue: $0) },
            explanation: ambiguityExplanation(shape)
        )
        let delayDiagnostics = DelayEstimateDiagnostics(
            selectedDelay: selectedResult.delay,
            candidatePeaks: shape.candidates,
            peakWidthSamples: shape.width,
            localPeakSharpness: shape.sharpness,
            searchBoundaryDistance: SampleCount(rawValue: boundaryDistance),
            channelResults: channelDiagnostics
        )
        let acousticDiagnostics = AcousticPathDiagnosticsAnalyzer().analyze(
            reference: reference.audio,
            recording: observed.audio,
            correlation: selectedResult.correlation
        )

        var metrics = makeMetrics(
            primaryPeak: primaryPeak,
            shape: shape,
            referenceRMS: referenceRMS,
            observedRMS: observedRMS,
            signalToNoise: snr,
            clippingRatio: clippingRatio,
            dcOffsetMagnitude: dcOffsetMagnitude,
            coverage: coverage,
            boundaryDistance: boundaryDistance,
            channelAgreement: channelAgreement,
            thresholds: thresholds
        )
        metrics.sort { $0.code.rawValue < $1.code.rawValue }
        let issues = makeIssues(
            primaryPeak: primaryPeak,
            shape: shape,
            correlationDiagnostics: correlationDiagnostics,
            referenceRMS: referenceRMS,
            observedRMS: observedRMS,
            signalToNoise: snr,
            clippingRatio: clippingRatio,
            dcOffsetMagnitude: dcOffsetMagnitude,
            coverage: coverage,
            boundaryDistance: boundaryDistance,
            channelAgreement: channelAgreement,
            reference: reference,
            observed: observed,
            thresholds: thresholds
        )
        let isUsable = primaryPeak.magnitude >= thresholds.minimumUsableCorrelation
        let score = confidenceScore(
            metrics: metrics,
            issues: issues,
            isUsable: isUsable,
            thresholds: thresholds
        )
        let level = qualityLevel(score: score.value, issues: issues, thresholds: thresholds)
        let quality = MeasurementQuality(
            level: level,
            confidence: score,
            summary: summary(for: level, issues: issues),
            metrics: metrics,
            issues: issues,
            peakAmbiguity: ambiguity,
            signal: signalAnalysis,
            delayDiagnostics: delayDiagnostics,
            acousticDiagnostics: acousticDiagnostics,
            shouldRemeasure: [.questionable, .poor, .invalid].contains(level)
        )
        return QualityAssessedMeasurement(
            delay: level == .invalid ? nil : selectedResult.delay,
            correlation: selectedResult.correlation,
            quality: quality
        )
    }

    private func invalidInputMeasurement(
        referenceRMS: Double,
        observedRMS: Double,
        clippingRatio: Double,
        dcOffsetMagnitude: Double,
        reference: ImportedAudioFile,
        observed: ImportedAudioFile,
        thresholds: MeasurementQualityThresholds
    ) -> QualityAssessedMeasurement {
        let issue = QualityIssue(
            code: .inputTooQuiet,
            severity: .fatal,
            userDescription: "The reference or recorded signal is effectively silent.",
            technicalDescription: "Reference RMS is \(referenceRMS); observed RMS is \(observedRMS); the invalid floor is \(thresholds.invalidInputRMS).",
            recommendedAction: "Check audio routing and input gain, then record the measurement again."
        )
        let metrics = basicInputMetrics(
            referenceRMS: referenceRMS,
            observedRMS: observedRMS,
            clippingRatio: clippingRatio,
            dcOffsetMagnitude: dcOffsetMagnitude,
            thresholds: thresholds
        )
        let signal = SignalQualityAnalysis(
            referenceRMS: referenceRMS,
            observedRMS: observedRMS,
            signalToNoiseDecibels: nil,
            clippingRatio: clippingRatio,
            dcOffsetMagnitude: dcOffsetMagnitude,
            referenceCoverageRatio: nil,
            isPolarityInverted: nil,
            appearsTruncated: false,
            channelsConsistent: reference.channelCount > 1 ? false : nil,
            channelDelaySpreadSamples: nil,
            channelPeakSpread: nil
        )
        let quality = MeasurementQuality(
            level: .invalid,
            confidence: confidenceScore(
                metrics: metrics,
                issues: [issue],
                isUsable: false,
                thresholds: thresholds
            ),
            summary: "No measurable reference signal was found, so no delay is reported.",
            metrics: metrics,
            issues: [issue],
            peakAmbiguity: emptyAmbiguity("No peaks were evaluated because the input was below the signal floor."),
            signal: signal,
            delayDiagnostics: DelayEstimateDiagnostics(
                selectedDelay: nil,
                candidatePeaks: [],
                peakWidthSamples: nil,
                localPeakSharpness: nil,
                searchBoundaryDistance: nil,
                channelResults: []
            ),
            shouldRemeasure: true
        )
        return QualityAssessedMeasurement(delay: nil, correlation: nil, quality: quality)
    }

    private func unavailableMeasurement(
        referenceRMS: Double,
        observedRMS: Double,
        clippingRatio: Double,
        dcOffsetMagnitude: Double,
        selectedDelay: DelayEstimate?
    ) -> QualityAssessedMeasurement {
        let issue = QualityIssue(
            code: .analysisUnavailable,
            severity: .fatal,
            userDescription: "Correlation diagnostics are unavailable.",
            technicalDescription: "Quality evaluation requires the searched correlation sequence and detailed primary peak.",
            recommendedAction: "Run the measurement again with quality analysis enabled."
        )
        let signal = SignalQualityAnalysis(
            referenceRMS: referenceRMS,
            observedRMS: observedRMS,
            signalToNoiseDecibels: nil,
            clippingRatio: clippingRatio,
            dcOffsetMagnitude: dcOffsetMagnitude,
            referenceCoverageRatio: nil,
            isPolarityInverted: nil,
            appearsTruncated: false,
            channelsConsistent: nil,
            channelDelaySpreadSamples: nil,
            channelPeakSpread: nil
        )
        let quality = MeasurementQuality(
            level: .invalid,
            confidence: ConfidenceScore(value: 0, components: []),
            summary: "The delay cannot be quality-checked and is not presented as valid.",
            metrics: [],
            issues: [issue],
            peakAmbiguity: emptyAmbiguity("No correlation sequence was available."),
            signal: signal,
            delayDiagnostics: DelayEstimateDiagnostics(
                selectedDelay: selectedDelay,
                candidatePeaks: [],
                peakWidthSamples: nil,
                localPeakSharpness: nil,
                searchBoundaryDistance: nil,
                channelResults: []
            ),
            shouldRemeasure: true
        )
        return QualityAssessedMeasurement(delay: nil, correlation: nil, quality: quality)
    }

    private func analyzePeakShape(
        sequence: CorrelationSequence,
        primaryPeak: CorrelationPeak,
        referenceCount: Int,
        observedCount: Int,
        thresholds: MeasurementQualityThresholds
    ) throws -> PeakShapeResult {
        let values = sequence.values
        let primaryIndex = Int(primaryPeak.lag.rawValue - sequence.firstLag)
        guard values.indices.contains(primaryIndex) else {
            return PeakShapeResult(
                candidates: [primaryPeak],
                primaryToSecondaryRatio: nil,
                peakToSidelobeRatio: 0,
                width: nil,
                sharpness: nil,
                hasSimilarPeaks: false,
                peakSpacings: [],
                periodicInterval: nil
            )
        }

        let primaryMagnitude = primaryPeak.magnitude
        let minimumCandidateMagnitude = primaryMagnitude * thresholds.candidateMinimumRelativeMagnitude
        var localPeaks: [CorrelationPeak] = []
        for index in values.indices {
            if index.isMultiple(of: 8_192) { try checkCancellation() }
            let magnitude = abs(Double(values[index]))
            guard magnitude >= minimumCandidateMagnitude else { continue }
            let left = index > values.startIndex ? abs(Double(values[index - 1])) : -Double.infinity
            let right = index + 1 < values.endIndex ? abs(Double(values[index + 1])) : -Double.infinity
            guard magnitude >= left, magnitude > right else { continue }
            let lag = sequence.firstLag + Int64(index)
            localPeaks.append(
                CorrelationPeak(
                    lag: SampleCount(rawValue: lag),
                    fractionalLag: parabolicLag(values: values, index: index, integerLag: lag),
                    value: Double(values[index]),
                    overlapCount: SampleCount(
                        rawValue: Int64(overlapCount(
                            referenceCount: referenceCount,
                            observedCount: observedCount,
                            lag: lag
                        ))
                    )
                )
            )
        }
        localPeaks.sort {
            if $0.magnitude == $1.magnitude { return $0.lag.rawValue < $1.lag.rawValue }
            return $0.magnitude > $1.magnitude
        }

        var separated: [CorrelationPeak] = [primaryPeak]
        for candidate in localPeaks where candidate.lag != primaryPeak.lag {
            if separated.allSatisfy({
                abs($0.lag.rawValue - candidate.lag.rawValue) > thresholds.candidateExclusionRadius
            }) {
                separated.append(candidate)
                if separated.count == thresholds.maximumPeakCandidates { break }
            }
        }
        let secondary = separated.dropFirst().max { $0.magnitude < $1.magnitude }
        let primaryToSecondaryRatio: Double? = secondary.map {
            $0.magnitude > Double.ulpOfOne
                ? primaryMagnitude / $0.magnitude
                : Double.greatestFiniteMagnitude
        } ?? (primaryMagnitude > 0 ? Double.greatestFiniteMagnitude : 0)
        let hasSimilarPeaks = secondary.map {
            $0.magnitude >= primaryMagnitude * thresholds.ambiguousPeakRelativeMagnitude
        } ?? false

        let similarByLag = separated
            .filter { $0.magnitude >= primaryMagnitude * thresholds.repeatedPeakRelativeMagnitude }
            .sorted { $0.lag.rawValue < $1.lag.rawValue }
        let spacings = zip(similarByLag, similarByLag.dropFirst()).map {
            $1.lag.rawValue - $0.lag.rawValue
        }
        let periodicInterval = periodicInterval(spacings: spacings, thresholds: thresholds)

        var sidelobeEnergy = 0.0
        var sidelobeCount = 0
        for index in values.indices {
            if abs(index - primaryIndex) <= Int(thresholds.candidateExclusionRadius) { continue }
            let value = Double(values[index])
            sidelobeEnergy += value * value
            sidelobeCount += 1
        }
        let sidelobeRMS = sidelobeCount > 0 ? sqrt(sidelobeEnergy / Double(sidelobeCount)) : 0
        let peakToSidelobeRatio = sidelobeRMS > Double.ulpOfOne
            ? primaryMagnitude / sidelobeRMS
            : (primaryMagnitude > 0 ? Double.greatestFiniteMagnitude : 0)

        return PeakShapeResult(
            candidates: separated,
            primaryToSecondaryRatio: primaryToSecondaryRatio,
            peakToSidelobeRatio: peakToSidelobeRatio,
            width: fullWidthAtHalfMaximum(values: values, peakIndex: primaryIndex),
            sharpness: localSharpness(values: values, peakIndex: primaryIndex),
            hasSimilarPeaks: hasSimilarPeaks,
            peakSpacings: spacings,
            periodicInterval: periodicInterval
        )
    }

    private func makeMetrics(
        primaryPeak: CorrelationPeak,
        shape: PeakShapeResult,
        referenceRMS: Double,
        observedRMS: Double,
        signalToNoise: Double,
        clippingRatio: Double,
        dcOffsetMagnitude: Double,
        coverage: Double,
        boundaryDistance: Int64,
        channelAgreement: ChannelAgreement,
        thresholds: MeasurementQualityThresholds
    ) -> [QualityMetric] {
        let weights = thresholds.weights
        var metrics: [QualityMetric] = [
            metric(
                .primaryCorrelation,
                primaryPeak.magnitude,
                .coefficient,
                scoreIncreasing(primaryPeak.magnitude, low: thresholds.minimumUsableCorrelation, good: thresholds.goodCorrelation, excellent: thresholds.excellentCorrelation, goodNormalizedScore: thresholds.goodMetricNormalizedScore),
                weights.primaryCorrelation,
                idealMinimum: thresholds.excellentCorrelation,
                explanation: "Magnitude of the normalized coefficient at the selected lag."
            ),
            metric(
                .peakToSidelobeRatio,
                shape.peakToSidelobeRatio,
                .ratio,
                scoreIncreasing(shape.peakToSidelobeRatio, low: thresholds.questionablePeakToSidelobeRatio, good: thresholds.goodPeakToSidelobeRatio, excellent: thresholds.excellentPeakToSidelobeRatio, goodNormalizedScore: thresholds.goodMetricNormalizedScore),
                weights.peakToSidelobeRatio,
                idealMinimum: thresholds.excellentPeakToSidelobeRatio,
                explanation: "Primary peak magnitude divided by RMS correlation outside its guard region."
            ),
            metric(
                .referenceRMS,
                referenceRMS,
                .normalizedAmplitude,
                inputLevelScore(referenceRMS, thresholds: thresholds),
                0,
                idealMinimum: thresholds.healthyInputRMS,
                explanation: "RMS level of the selected reference channel."
            ),
            metric(
                .observedRMS,
                observedRMS,
                .normalizedAmplitude,
                inputLevelScore(observedRMS, thresholds: thresholds),
                weights.inputLevel,
                idealMinimum: thresholds.healthyInputRMS,
                explanation: "RMS level of the selected recorded channel."
            ),
            metric(
                .signalToNoiseDecibels,
                signalToNoise,
                .decibels,
                scoreIncreasing(signalToNoise, low: thresholds.poorSignalToNoiseDecibels, good: thresholds.goodSignalToNoiseDecibels, excellent: thresholds.excellentSignalToNoiseDecibels, goodNormalizedScore: thresholds.goodMetricNormalizedScore),
                weights.signalToNoise,
                idealMinimum: thresholds.excellentSignalToNoiseDecibels,
                explanation: "Least-squares aligned reference energy relative to residual energy."
            ),
            metric(
                .clippingRatio,
                clippingRatio,
                .fraction,
                scoreDecreasing(clippingRatio, good: thresholds.clippingWarningRatio, poor: thresholds.clippingSevereRatio),
                weights.clipping,
                idealMaximum: thresholds.clippingWarningRatio,
                explanation: "Fraction of recorded PCM samples at normalized full scale."
            ),
            metric(
                .dcOffsetMagnitude,
                dcOffsetMagnitude,
                .normalizedAmplitude,
                scoreDecreasing(dcOffsetMagnitude, good: thresholds.dcOffsetWarningMagnitude, poor: thresholds.dcOffsetSevereMagnitude),
                weights.dcOffset,
                idealMaximum: thresholds.dcOffsetWarningMagnitude,
                explanation: "Largest absolute per-channel mean sample value."
            ),
            metric(
                .referenceCoverageRatio,
                coverage,
                .fraction,
                scoreIncreasing(coverage, low: thresholds.coverageSevereRatio, good: thresholds.coverageWarningRatio, excellent: 1, goodNormalizedScore: thresholds.goodMetricNormalizedScore),
                weights.referenceCoverage,
                idealMinimum: thresholds.coverageWarningRatio,
                explanation: "Fraction of reference frames participating at the selected lag."
            ),
            metric(
                .searchBoundaryDistanceSamples,
                Double(boundaryDistance),
                .samples,
                scoreIncreasing(Double(boundaryDistance), low: 0, good: Double(thresholds.searchBoundaryWarningSamples), excellent: Double(thresholds.searchBoundaryGoodSamples), goodNormalizedScore: thresholds.goodMetricNormalizedScore),
                weights.searchBoundary,
                idealMinimum: Double(thresholds.searchBoundaryGoodSamples),
                explanation: "Distance from the selected lag to the nearest searched boundary."
            ),
            metric(
                .invertedPolarity,
                primaryPeak.value < 0 ? 1 : 0,
                .boolean,
                1,
                0,
                idealMaximum: 0,
                explanation: "A signed negative peak indicates inverted polarity, not missing signal."
            ),
            metric(
                .similarPeakCount,
                Double(shape.candidates.filter { $0.magnitude >= primaryPeak.magnitude * thresholds.repeatedPeakRelativeMagnitude }.count),
                .count,
                shape.hasSimilarPeaks ? 0 : 1,
                0,
                idealMaximum: 1,
                explanation: "Number of separated local peaks close to the selected peak magnitude."
            ),
            metric(
                .truncationRatio,
                1 - coverage,
                .fraction,
                scoreIncreasing(coverage, low: thresholds.coverageSevereRatio, good: thresholds.coverageWarningRatio, excellent: 1, goodNormalizedScore: thresholds.goodMetricNormalizedScore),
                0,
                idealMaximum: 1 - thresholds.coverageWarningRatio,
                explanation: "Reference fraction absent from the correlation overlap."
            )
        ]
        if let ratio = shape.primaryToSecondaryRatio {
            metrics.append(metric(
                .primaryToSecondaryRatio,
                ratio,
                .ratio,
                scoreIncreasing(ratio, low: thresholds.questionablePrimaryToSecondaryRatio, good: thresholds.goodPrimaryToSecondaryRatio, excellent: thresholds.excellentPrimaryToSecondaryRatio, goodNormalizedScore: thresholds.goodMetricNormalizedScore),
                weights.primaryToSecondaryRatio,
                idealMinimum: thresholds.excellentPrimaryToSecondaryRatio,
                explanation: "Selected peak magnitude divided by the strongest separated local peak."
            ))
        }
        if let width = shape.width {
            metrics.append(metric(
                .peakWidthSamples,
                width,
                .samples,
                scoreDecreasing(width, good: thresholds.goodPeakWidthSamples, poor: thresholds.poorPeakWidthSamples),
                weights.peakWidth,
                idealMaximum: thresholds.goodPeakWidthSamples,
                explanation: "Full width of the absolute peak at half maximum."
            ))
        }
        if let sharpness = shape.sharpness {
            metrics.append(metric(
                .localPeakSharpness,
                sharpness,
                .coefficient,
                scoreIncreasing(sharpness, low: 0, good: thresholds.goodLocalSharpness, excellent: thresholds.excellentLocalSharpness, goodNormalizedScore: thresholds.goodMetricNormalizedScore),
                weights.localSharpness,
                idealMinimum: thresholds.goodLocalSharpness,
                explanation: "Normalized curvature from the peak to its immediate neighbors."
            ))
        }
        if let delaySpread = channelAgreement.delaySpread {
            let peakPenalty = channelAgreement.peakSpread.map {
                scoreDecreasing($0, good: thresholds.channelPeakWarningDifference, poor: thresholds.channelPeakSevereDifference)
            } ?? 1
            let score = min(
                scoreDecreasing(delaySpread, good: thresholds.channelDelayWarningSamples, poor: thresholds.channelDelaySevereSamples),
                peakPenalty
            )
            metrics.append(metric(
                .channelDelaySpreadSamples,
                delaySpread,
                .samples,
                score,
                weights.channelAgreement,
                idealMaximum: thresholds.channelDelayWarningSamples,
                explanation: "Difference between the largest and smallest per-channel delay."
            ))
        }
        if let peakSpread = channelAgreement.peakSpread {
            metrics.append(metric(
                .channelPeakSpread,
                peakSpread,
                .coefficient,
                scoreDecreasing(peakSpread, good: thresholds.channelPeakWarningDifference, poor: thresholds.channelPeakSevereDifference),
                0,
                idealMaximum: thresholds.channelPeakWarningDifference,
                explanation: "Difference between per-channel normalized peak magnitudes."
            ))
        }
        return metrics
    }

    private func makeIssues(
        primaryPeak: CorrelationPeak,
        shape: PeakShapeResult,
        correlationDiagnostics: AnalysisDiagnostics,
        referenceRMS: Double,
        observedRMS: Double,
        signalToNoise: Double,
        clippingRatio: Double,
        dcOffsetMagnitude: Double,
        coverage: Double,
        boundaryDistance: Int64,
        channelAgreement: ChannelAgreement,
        reference: ImportedAudioFile,
        observed: ImportedAudioFile,
        thresholds: MeasurementQualityThresholds
    ) -> [QualityIssue] {
        var issues: [QualityIssue] = []
        if min(referenceRMS, observedRMS) < thresholds.quietInputRMS {
            issues.append(QualityIssue(
                code: .inputTooQuiet,
                severity: .warning,
                userDescription: "The measurement signal is quiet.",
                technicalDescription: "The lower selected-channel RMS is \(min(referenceRMS, observedRMS)); the quiet boundary is \(thresholds.quietInputRMS).",
                recommendedAction: "Increase playback or recording gain without causing clipping, then measure again."
            ))
        }
        if primaryPeak.magnitude < thresholds.minimumUsableCorrelation {
            issues.append(QualityIssue(
                code: .weakCorrelationPeak,
                severity: .fatal,
                userDescription: "No usable match to the reference signal was found.",
                technicalDescription: "Peak magnitude \(primaryPeak.magnitude) is below \(thresholds.minimumUsableCorrelation).",
                recommendedAction: "Verify routing, reduce noise, and repeat the measurement."
            ))
        } else if primaryPeak.magnitude < thresholds.goodCorrelation {
            issues.append(QualityIssue(
                code: .weakCorrelationPeak,
                severity: .warning,
                userDescription: "The correlation match is weaker than expected.",
                technicalDescription: "Peak magnitude is \(primaryPeak.magnitude); the good boundary is \(thresholds.goodCorrelation).",
                recommendedAction: "Use a stronger reference signal or reduce environmental noise."
            ))
        }
        if shape.hasSimilarPeaks {
            issues.append(QualityIssue(
                code: .ambiguousPeak,
                severity: .warning,
                userDescription: "More than one delay candidate is similarly strong.",
                technicalDescription: "The strongest separated candidates differ by less than \((1 - thresholds.ambiguousPeakRelativeMagnitude) * 100) percent.",
                recommendedAction: "Use a less repetitive reference signal or restrict the expected delay range."
            ))
        } else if let ratio = shape.primaryToSecondaryRatio,
                  ratio < thresholds.goodPrimaryToSecondaryRatio {
            issues.append(QualityIssue(
                code: .lowPeakSeparation,
                severity: .warning,
                userDescription: "The selected peak is not clearly separated from another candidate.",
                technicalDescription: "Primary-to-secondary ratio is \(ratio); the good boundary is \(thresholds.goodPrimaryToSecondaryRatio).",
                recommendedAction: "Repeat with a longer non-periodic reference signal."
            ))
        }
        if let interval = shape.periodicInterval {
            issues.append(QualityIssue(
                code: .periodicPeakPattern,
                severity: .warning,
                userDescription: "Correlation candidates repeat at a regular interval.",
                technicalDescription: "Similar peaks have an estimated interval of \(interval) samples.",
                recommendedAction: "Avoid repeated chirps or periodic test material, or constrain the delay search range."
            ))
        }
        if clippingRatio > thresholds.clippingWarningRatio {
            issues.append(QualityIssue(
                code: .clippingDetected,
                severity: clippingRatio >= thresholds.clippingSevereRatio ? .error : .warning,
                userDescription: "The recording contains clipped samples.",
                technicalDescription: "Clipping ratio is \(clippingRatio); the warning boundary is \(thresholds.clippingWarningRatio).",
                recommendedAction: "Lower playback or input gain and record again."
            ))
        }
        if signalToNoise < thresholds.goodSignalToNoiseDecibels {
            issues.append(QualityIssue(
                code: .excessiveNoise,
                severity: signalToNoise < thresholds.poorSignalToNoiseDecibels ? .error : .warning,
                userDescription: "Noise or unmodeled audio is affecting the match.",
                technicalDescription: "Aligned least-squares SNR is \(signalToNoise) dB; the good boundary is \(thresholds.goodSignalToNoiseDecibels) dB.",
                recommendedAction: "Reduce background noise, use wired routing, or increase clean signal level."
            ))
        }
        if dcOffsetMagnitude > thresholds.dcOffsetWarningMagnitude {
            issues.append(QualityIssue(
                code: .dcOffsetDetected,
                severity: dcOffsetMagnitude >= thresholds.dcOffsetSevereMagnitude ? .error : .warning,
                userDescription: "The recording has a measurable DC offset.",
                technicalDescription: "Maximum absolute channel mean is \(dcOffsetMagnitude); the warning boundary is \(thresholds.dcOffsetWarningMagnitude).",
                recommendedAction: "Enable explicit DC removal or inspect the capture device."
            ))
        }
        if coverage < thresholds.coverageWarningRatio {
            issues.append(QualityIssue(
                code: .referencePartiallyMissing,
                severity: coverage < thresholds.coverageSevereRatio ? .error : .warning,
                userDescription: "Only part of the reference signal is present in the usable overlap.",
                technicalDescription: "Reference coverage is \(coverage); the expected boundary is \(thresholds.coverageWarningRatio).",
                recommendedAction: "Record more pre-roll and post-roll around the test signal."
            ))
        }
        if coverage < thresholds.coverageSevereRatio {
            issues.append(QualityIssue(
                code: .possibleTruncation,
                severity: .error,
                userDescription: "The recording appears to truncate the reference signal.",
                technicalDescription: "More than \((1 - thresholds.coverageSevereRatio) * 100) percent of the reference is outside the overlap.",
                recommendedAction: "Increase recording duration and repeat the measurement."
            ))
        }
        if boundaryDistance <= thresholds.searchBoundaryWarningSamples {
            issues.append(QualityIssue(
                code: .peakAtSearchBoundary,
                severity: .warning,
                userDescription: boundaryDistance == 0
                    ? "The selected delay is at the search boundary."
                    : "The selected delay is very close to the search boundary.",
                technicalDescription: "Nearest boundary distance is \(boundaryDistance) samples; the warning boundary is \(thresholds.searchBoundaryWarningSamples).",
                recommendedAction: "Widen or shift the allowed delay range and analyze again."
            ))
        }
        if correlationDiagnostics.searchRangeWasClamped {
            issues.append(QualityIssue(
                code: .searchRangeClamped,
                severity: .information,
                userDescription: "The requested search range exceeded usable correlation lags.",
                technicalDescription: "The range was intersected with lags meeting the minimum overlap requirement.",
                recommendedAction: "No action is required unless the expected delay lies outside the searched range."
            ))
        }
        if primaryPeak.value < 0 {
            issues.append(QualityIssue(
                code: .polarityInverted,
                severity: .information,
                userDescription: "The recorded signal has inverted polarity.",
                technicalDescription: "The selected signed normalized correlation is \(primaryPeak.value).",
                recommendedAction: "Delay remains measurable; inspect wiring or processing if polarity matters."
            ))
        }
        if let width = shape.width, width > thresholds.goodPeakWidthSamples {
            issues.append(QualityIssue(
                code: .broadCorrelationPeak,
                severity: .warning,
                userDescription: "The correlation peak is broad.",
                technicalDescription: "Half-maximum width is \(width) samples; the preferred maximum is \(thresholds.goodPeakWidthSamples).",
                recommendedAction: "Use a wider-band or longer reference signal for more precise timing."
            ))
        }
        if channelAgreement.consistent == false {
            let severe = (channelAgreement.delaySpread ?? 0) >= thresholds.channelDelaySevereSamples
                || (channelAgreement.peakSpread ?? 0) >= thresholds.channelPeakSevereDifference
                || channelAgreement.missingChannelResult
            let delayDescription = channelAgreement.delaySpread.map { String($0) } ?? "unavailable"
            let peakDescription = channelAgreement.peakSpread.map { String($0) } ?? "unavailable"
            issues.append(QualityIssue(
                code: .channelsDisagree,
                severity: severe ? .error : .warning,
                userDescription: "Left and right channels do not agree on the delay.",
                technicalDescription: "Delay spread is \(delayDescription) samples; peak spread is \(peakDescription).",
                recommendedAction: "Inspect channel routing and analyze channels separately before measuring again."
            ))
        }
        if reference.wasResampled || observed.wasResampled {
            issues.append(QualityIssue(
                code: .sampleRateConverted,
                severity: .information,
                userDescription: "One or both inputs were explicitly resampled.",
                technicalDescription: "The preprocessing log contains an AVAudioConverter sample-rate conversion.",
                recommendedAction: "Keep the conversion record with the report; use native matching rates when possible."
            ))
        }
        return issues
    }

    private func confidenceScore(
        metrics: [QualityMetric],
        issues: [QualityIssue],
        isUsable: Bool,
        thresholds: MeasurementQualityThresholds
    ) -> ConfidenceScore {
        let weighted = metrics.filter { $0.weight > 0 }
        let totalWeight = weighted.reduce(0) { $0 + $1.weight }
        guard isUsable, totalWeight > 0 else {
            return ConfidenceScore(
                value: 0,
                components: weighted.map {
                    ConfidenceComponent(
                        metric: $0.code,
                        normalizedScore: $0.normalizedScore,
                        weight: $0.weight / max(totalWeight, Double.ulpOfOne),
                        weightedContribution: 0
                    )
                }
            )
        }
        let raw = weighted.reduce(0) { $0 + $1.normalizedScore * $1.weight } / totalWeight
        let cap = qualityCap(for: issues, thresholds: thresholds)
        let value = min(raw, cap)
        let scale = raw > Double.ulpOfOne ? value / raw : 0
        let components = weighted.map {
            let normalizedWeight = $0.weight / totalWeight
            return ConfidenceComponent(
                metric: $0.code,
                normalizedScore: $0.normalizedScore,
                weight: normalizedWeight,
                weightedContribution: $0.normalizedScore * normalizedWeight * scale
            )
        }
        return ConfidenceScore(value: value, components: components)
    }

    private func qualityCap(
        for issues: [QualityIssue],
        thresholds: MeasurementQualityThresholds
    ) -> Double {
        if issues.contains(where: { $0.severity == .fatal }) { return 0 }
        if issues.contains(where: { $0.severity == .error }) { return thresholds.errorScoreCap }
        if issues.contains(where: {
            [.ambiguousPeak, .periodicPeakPattern, .peakAtSearchBoundary,
             .referencePartiallyMissing, .excessiveNoise, .channelsDisagree,
             .clippingDetected, .lowPeakSeparation].contains($0.code)
        }) { return thresholds.uncertaintyScoreCap }
        if issues.contains(where: { $0.severity == .warning }) { return thresholds.warningScoreCap }
        return 1
    }

    private func qualityLevel(
        score: Double,
        issues: [QualityIssue],
        thresholds: MeasurementQualityThresholds
    ) -> MeasurementQualityLevel {
        if issues.contains(where: { $0.severity == .fatal }) { return .invalid }
        if score >= thresholds.excellentScoreMinimum { return .excellent }
        if score >= thresholds.goodScoreMinimum { return .good }
        if score >= thresholds.questionableScoreMinimum { return .questionable }
        return .poor
    }

    private func summary(
        for level: MeasurementQualityLevel,
        issues: [QualityIssue]
    ) -> String {
        switch level {
        case .excellent:
            "The delay is supported by a strong, isolated peak and clean input signal."
        case .good:
            "The delay is credible, with only minor quality limitations."
        case .questionable:
            "A delay candidate was found, but one or more warnings make it uncertain."
        case .poor:
            "The selected delay has substantial signal or peak-quality problems and should be remeasured."
        case .invalid:
            issues.contains(where: { $0.code == .weakCorrelationPeak })
                ? "No trustworthy reference match was found, so no delay is reported."
                : "The input cannot support a trustworthy delay measurement."
        }
    }

    private func signalToNoiseEstimate(
        reference: [Float],
        observed: [Float],
        lag: Int64,
        finiteLimit: Double
    ) throws -> Double {
        let overlap = overlapRanges(referenceCount: reference.count, observedCount: observed.count, lag: lag)
        guard overlap.reference.count > 0 else { return -finiteLimit }
        var referenceEnergy = 0.0
        var cross = 0.0
        for offset in 0..<overlap.reference.count {
            if offset.isMultiple(of: 8_192) { try checkCancellation() }
            let x = Double(reference[overlap.reference.lowerBound + offset])
            let y = Double(observed[overlap.observed.lowerBound + offset])
            referenceEnergy += x * x
            cross += x * y
        }
        guard referenceEnergy > Double.leastNormalMagnitude else { return -finiteLimit }
        let gain = cross / referenceEnergy
        var signalEnergy = 0.0
        var residualEnergy = 0.0
        for offset in 0..<overlap.reference.count {
            if offset.isMultiple(of: 8_192) { try checkCancellation() }
            let x = Double(reference[overlap.reference.lowerBound + offset])
            let y = Double(observed[overlap.observed.lowerBound + offset])
            let fitted = gain * x
            let residual = y - fitted
            signalEnergy += fitted * fitted
            residualEnergy += residual * residual
        }
        guard signalEnergy > Double.leastNormalMagnitude else { return -finiteLimit }
        guard residualEnergy > Double.leastNormalMagnitude else { return finiteLimit }
        return max(-finiteLimit, min(finiteLimit, 10 * log10(signalEnergy / residualEnergy)))
    }

    private func analyzeChannelAgreement(
        _ results: [(channel: Int, result: DelayAnalysisResult?)],
        thresholds: MeasurementQualityThresholds
    ) -> ChannelAgreement {
        guard results.count > 1 else {
            return ChannelAgreement(
                consistent: nil,
                delaySpread: nil,
                peakSpread: nil,
                missingChannelResult: false
            )
        }
        let available = results.compactMap(\.result)
        guard available.count == results.count else {
            return ChannelAgreement(
                consistent: false,
                delaySpread: nil,
                peakSpread: nil,
                missingChannelResult: true
            )
        }
        let delays = available.map {
            $0.delay.fractionalSampleOffset ?? Double($0.delay.sampleOffset.rawValue)
        }
        let peaks = available.map { abs($0.correlation.normalizedPeak) }
        let delaySpread = (delays.max() ?? 0) - (delays.min() ?? 0)
        let peakSpread = (peaks.max() ?? 0) - (peaks.min() ?? 0)
        return ChannelAgreement(
            consistent: delaySpread <= thresholds.channelDelayWarningSamples
                && peakSpread <= thresholds.channelPeakWarningDifference,
            delaySpread: delaySpread,
            peakSpread: peakSpread,
            missingChannelResult: false
        )
    }

    private func basicInputMetrics(
        referenceRMS: Double,
        observedRMS: Double,
        clippingRatio: Double,
        dcOffsetMagnitude: Double,
        thresholds: MeasurementQualityThresholds
    ) -> [QualityMetric] {
        [
            metric(.referenceRMS, referenceRMS, .normalizedAmplitude, inputLevelScore(referenceRMS, thresholds: thresholds), 0, idealMinimum: thresholds.healthyInputRMS, explanation: "RMS level of the selected reference channel."),
            metric(.observedRMS, observedRMS, .normalizedAmplitude, inputLevelScore(observedRMS, thresholds: thresholds), thresholds.weights.inputLevel, idealMinimum: thresholds.healthyInputRMS, explanation: "RMS level of the selected recorded channel."),
            metric(.clippingRatio, clippingRatio, .fraction, scoreDecreasing(clippingRatio, good: thresholds.clippingWarningRatio, poor: thresholds.clippingSevereRatio), thresholds.weights.clipping, idealMaximum: thresholds.clippingWarningRatio, explanation: "Fraction of recorded PCM samples at full scale."),
            metric(.dcOffsetMagnitude, dcOffsetMagnitude, .normalizedAmplitude, scoreDecreasing(dcOffsetMagnitude, good: thresholds.dcOffsetWarningMagnitude, poor: thresholds.dcOffsetSevereMagnitude), thresholds.weights.dcOffset, idealMaximum: thresholds.dcOffsetWarningMagnitude, explanation: "Largest absolute per-channel mean.")
        ]
    }

    private func metric(
        _ code: QualityMetricCode,
        _ value: Double,
        _ unit: QualityMetricUnit,
        _ normalizedScore: Double,
        _ weight: Double,
        idealMinimum: Double? = nil,
        idealMaximum: Double? = nil,
        explanation: String
    ) -> QualityMetric {
        QualityMetric(
            code: code,
            value: value.isFinite ? value : Double.greatestFiniteMagnitude,
            unit: unit,
            normalizedScore: max(0, min(1, normalizedScore)),
            weight: max(0, weight),
            idealMinimum: idealMinimum,
            idealMaximum: idealMaximum,
            explanation: explanation
        )
    }

    private func scoreIncreasing(
        _ value: Double,
        low: Double,
        good: Double,
        excellent: Double,
        goodNormalizedScore: Double
    ) -> Double {
        if value <= low { return 0 }
        if value < good {
            return goodNormalizedScore * (value - low) / max(Double.ulpOfOne, good - low)
        }
        if value < excellent {
            return goodNormalizedScore
                + (1 - goodNormalizedScore) * (value - good)
                / max(Double.ulpOfOne, excellent - good)
        }
        return 1
    }

    private func scoreDecreasing(_ value: Double, good: Double, poor: Double) -> Double {
        if value <= good { return 1 }
        if value >= poor { return 0 }
        return 1 - (value - good) / max(Double.ulpOfOne, poor - good)
    }

    private func inputLevelScore(_ value: Double, thresholds: MeasurementQualityThresholds) -> Double {
        scoreIncreasing(
            value,
            low: thresholds.invalidInputRMS,
            good: thresholds.quietInputRMS,
            excellent: thresholds.healthyInputRMS,
            goodNormalizedScore: thresholds.goodMetricNormalizedScore
        )
    }

    private func fullWidthAtHalfMaximum(values: [Float], peakIndex: Int) -> Double? {
        guard values.indices.contains(peakIndex) else { return nil }
        let half = abs(Double(values[peakIndex])) * 0.5
        guard half > 0 else { return nil }
        var left = peakIndex
        while left > 0, abs(Double(values[left])) >= half { left -= 1 }
        let leftPosition: Double
        if left == 0, abs(Double(values[left])) >= half {
            leftPosition = 0
        } else {
            let below = abs(Double(values[left]))
            let above = abs(Double(values[left + 1]))
            leftPosition = Double(left) + (half - below) / max(Double.ulpOfOne, above - below)
        }
        var right = peakIndex
        while right + 1 < values.count, abs(Double(values[right])) >= half { right += 1 }
        let rightPosition: Double
        if right == values.count - 1, abs(Double(values[right])) >= half {
            rightPosition = Double(right)
        } else {
            let above = abs(Double(values[right - 1]))
            let below = abs(Double(values[right]))
            rightPosition = Double(right - 1) + (above - half) / max(Double.ulpOfOne, above - below)
        }
        return max(0, rightPosition - leftPosition)
    }

    private func localSharpness(values: [Float], peakIndex: Int) -> Double? {
        guard peakIndex > 0, peakIndex + 1 < values.count else { return nil }
        let center = abs(Double(values[peakIndex]))
        guard center > Double.ulpOfOne else { return nil }
        let neighbors = (abs(Double(values[peakIndex - 1])) + abs(Double(values[peakIndex + 1]))) * 0.5
        return max(0, min(1, (center - neighbors) / center))
    }

    private func parabolicLag(values: [Float], index: Int, integerLag: Int64) -> Double? {
        guard index > 0, index + 1 < values.count else { return nil }
        let left = abs(Double(values[index - 1]))
        let center = abs(Double(values[index]))
        let right = abs(Double(values[index + 1]))
        let denominator = left - 2 * center + right
        guard denominator < -Double.ulpOfOne else { return nil }
        let offset = 0.5 * (left - right) / denominator
        guard offset.isFinite, abs(offset) <= 1 else { return nil }
        return Double(integerLag) + offset
    }

    private func periodicInterval(
        spacings: [Int64],
        thresholds: MeasurementQualityThresholds
    ) -> Int64? {
        guard spacings.count >= 2 else { return nil }
        let sorted = spacings.sorted()
        let median = sorted[sorted.count / 2]
        let tolerance = max(
            thresholds.periodicSpacingToleranceSamples,
            Int64((Double(median) * thresholds.periodicSpacingToleranceRatio).rounded())
        )
        return spacings.allSatisfy { abs($0 - median) <= tolerance } ? median : nil
    }

    private func ambiguityExplanation(_ shape: PeakShapeResult) -> String {
        if let interval = shape.periodicInterval {
            return "Similar correlation peaks repeat approximately every \(interval) samples."
        }
        if shape.hasSimilarPeaks {
            return "At least two separated correlation peaks have nearly equal magnitude."
        }
        return "The selected peak is distinguishable from other local candidates."
    }

    private func emptyAmbiguity(_ explanation: String) -> PeakAmbiguity {
        PeakAmbiguity(
            candidates: [],
            primaryToSecondaryRatio: nil,
            hasSimilarPeaks: false,
            peakSpacings: [],
            periodicInterval: nil,
            explanation: explanation
        )
    }

    private func channelSamples(_ buffer: AudioSampleBuffer, channel: Int) throws -> [Float] {
        if buffer.channelCount == 1 { return buffer.samples }
        return try buffer.withUnsafeChannelSamples(channel: channel) { Array($0) }
    }

    private func rootMeanSquare(_ samples: [Float]) throws -> Double {
        guard !samples.isEmpty else { return 0 }
        var energy = 0.0
        for index in samples.indices {
            if index.isMultiple(of: 8_192) { try checkCancellation() }
            let value = Double(samples[index])
            energy += value * value
        }
        return sqrt(energy / Double(samples.count))
    }

    private func overlapCount(referenceCount: Int, observedCount: Int, lag: Int64) -> Int {
        overlapRanges(referenceCount: referenceCount, observedCount: observedCount, lag: lag).reference.count
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw CorrelationAnalysisError.cancelled }
    }

    private func overlapRanges(
        referenceCount: Int,
        observedCount: Int,
        lag: Int64
    ) -> (reference: Range<Int>, observed: Range<Int>) {
        let referenceStart = max(0, Int(-min(0, lag)))
        let referenceEnd = min(referenceCount, observedCount - Int(lag))
        let count = max(0, referenceEnd - referenceStart)
        let observedStart = referenceStart + Int(lag)
        return (
            referenceStart..<(referenceStart + count),
            observedStart..<(observedStart + count)
        )
    }
}

private struct PeakShapeResult {
    let candidates: [CorrelationPeak]
    let primaryToSecondaryRatio: Double?
    let peakToSidelobeRatio: Double
    let width: Double?
    let sharpness: Double?
    let hasSimilarPeaks: Bool
    let peakSpacings: [Int64]
    let periodicInterval: Int64?
}

private struct ChannelAgreement {
    let consistent: Bool?
    let delaySpread: Double?
    let peakSpread: Double?
    let missingChannelResult: Bool
}
