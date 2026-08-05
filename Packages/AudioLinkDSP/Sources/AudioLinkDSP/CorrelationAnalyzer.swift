@preconcurrency import Accelerate
import AudioLinkCore
import Foundation

/// Computes the linear cross-correlation
/// `r[lag] = sum(reference[i] * observed[i + lag])` over valid indices.
public struct CorrelationEngine: Sendable {
    private let fftCache: FFTSetupCache

    public init(maximumCachedFFTSetups: Int = 4) {
        fftCache = FFTSetupCache(maximumEntryCount: max(1, maximumCachedFFTSetups))
    }

    public func correlate(
        reference: [Float],
        observed: [Float],
        configuration: CorrelationConfiguration = .init()
    ) async throws -> CorrelationResult {
        let task = Task.detached(priority: .userInitiated) {
            try correlateSynchronously(
                reference: reference,
                observed: observed,
                configuration: configuration
            )
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw CorrelationAnalysisError.cancelled
        }
    }

    /// Synchronous entry point for deterministic tests and command-line tools.
    /// Applications should normally use the async overload.
    public func correlateSynchronously(
        reference: [Float],
        observed: [Float],
        configuration: CorrelationConfiguration = .init()
    ) throws -> CorrelationResult {
        do {
            try Task.checkCancellation()
            let context = try CorrelationContext(
                reference: reference,
                observed: observed,
                configuration: configuration
            )
            let implementation = selectImplementation(context: context, configuration: configuration)

            let fftNumerators: FFTNumerators?
            switch implementation {
            case .direct:
                fftNumerators = nil
            case .fft:
                fftNumerators = try fftCorrelationNumerators(reference: reference, observed: observed)
            }

            let searchValues = try values(
                in: context.searchedLagRange,
                context: context,
                implementation: implementation,
                fftNumerators: fftNumerators
            )
            let selected = try selectPeaks(
                values: searchValues,
                firstLag: context.searchedLagRange.minimum,
                context: context
            )

            let interpolation = interpolate(
                peakIndex: selected.primaryIndex,
                values: searchValues,
                selection: configuration.peakSelection,
                enabled: configuration.interpolateSubsample
            )
            let primaryLag = context.searchedLagRange.minimum + Int64(selected.primaryIndex)
            let primaryPeak = CorrelationPeak(
                lag: SampleCount(rawValue: primaryLag),
                fractionalLag: interpolation.offset.map { Double(primaryLag) + $0 },
                value: Double(searchValues[selected.primaryIndex]),
                overlapCount: SampleCount(rawValue: Int64(context.overlapCount(at: primaryLag)))
            )
            let secondaryPeak = selected.secondaryIndex.map { index in
                let lag = context.searchedLagRange.minimum + Int64(index)
                return CorrelationPeak(
                    lag: SampleCount(rawValue: lag),
                    value: Double(searchValues[index]),
                    overlapCount: SampleCount(rawValue: Int64(context.overlapCount(at: lag)))
                )
            }

            let peakMagnitude = primaryPeak.magnitude
            let secondaryMagnitude = secondaryPeak?.magnitude ?? 0
            let ratio: Double
            if secondaryMagnitude > Double.ulpOfOne {
                ratio = peakMagnitude / secondaryMagnitude
            } else if peakMagnitude > 0 {
                ratio = Double.greatestFiniteMagnitude
            } else {
                ratio = 0
            }
            let ambiguityLimit = peakMagnitude * (1 - configuration.ambiguityTolerance)
            let isAmbiguous = secondaryMagnitude >= ambiguityLimit && secondaryMagnitude > 0
            let passesThresholds = peakMagnitude >= configuration.minimumPeakMagnitude
                && ratio >= configuration.minimumPeakToSidelobeRatio
            let validity: DelayAnalysisValidity = isAmbiguous
                ? .ambiguous
                : (passesThresholds ? .valid : .lowConfidence)
            let confidence = confidence(
                peakMagnitude: peakMagnitude,
                ratio: ratio,
                validity: validity,
                configuration: configuration
            )

            let outputSequence: CorrelationSequence?
            switch configuration.sequenceOutput {
            case .none:
                outputSequence = nil
            case .searchedRange:
                outputSequence = CorrelationSequence(
                    firstLag: context.searchedLagRange.minimum,
                    values: searchValues
                )
            case .full:
                outputSequence = CorrelationSequence(
                    firstLag: context.fullLagRange.minimum,
                    values: try values(
                        in: context.fullLagRange,
                        context: context,
                        implementation: implementation,
                        fftNumerators: fftNumerators
                    )
                )
            }

            var notes: [String] = []
            if validity == .lowConfidence {
                notes.append("The selected peak did not meet the configured magnitude or peak-to-sidelobe threshold.")
            } else if validity == .ambiguous {
                notes.append("A second peak is within the configured ambiguity tolerance of the primary peak.")
            }
            if context.searchRangeWasClamped {
                notes.append("The requested search range was clamped to lags with sufficient overlap.")
            }
            if interpolation.status != .applied {
                notes.append("Sub-sample interpolation was not applied: \(interpolation.status.rawValue).")
            }

            let fftLength = fftNumerators?.fftLength
            let diagnostics = AnalysisDiagnostics(
                implementation: implementation,
                validity: validity,
                validLagRange: context.validLagRange,
                searchedLagRange: context.searchedLagRange,
                searchRangeWasClamped: context.searchRangeWasClamped,
                peakAtSearchBoundary: selected.primaryIndex == 0 || selected.primaryIndex == searchValues.count - 1,
                referenceRMS: context.referenceRMS,
                observedRMS: context.observedRMS,
                minimumOverlapCount: SampleCount(rawValue: Int64(context.minimumOverlapCount)),
                fftLength: fftLength,
                estimatedWorkingSetBytes: estimatedWorkingSetBytes(
                    context: context,
                    implementation: implementation,
                    fftLength: fftLength,
                    outputCount: outputSequence?.values.count ?? 0
                ),
                interpolationStatus: interpolation.status,
                notes: notes
            )

            return CorrelationResult(
                peakOffset: primaryPeak.lag,
                normalizedPeak: primaryPeak.value,
                peakToSidelobeRatio: ratio,
                confidence: confidence,
                primaryPeak: primaryPeak,
                secondaryPeak: secondaryPeak,
                sequence: outputSequence,
                diagnostics: diagnostics
            )
        } catch is CancellationError {
            throw CorrelationAnalysisError.cancelled
        }
    }

    private func selectImplementation(
        context: CorrelationContext,
        configuration: CorrelationConfiguration
    ) -> CorrelationImplementation {
        switch configuration.method {
        case .direct:
            return .direct
        case .fft:
            return .fft
        case .automatic:
            let range = configuration.sequenceOutput == .full
                ? context.fullLagRange
                : context.searchedLagRange
            let lagCount = max(0, range.count)
            let (operations, overflow) = lagCount.multipliedReportingOverflow(
                by: Int64(context.reference.count)
            )
            return !overflow && operations <= configuration.directOperationLimit ? .direct : .fft
        }
    }

    private func values(
        in range: SampleLagRange,
        context: CorrelationContext,
        implementation: CorrelationImplementation,
        fftNumerators: FFTNumerators?
    ) throws -> [Float] {
        guard range.count > 0, range.count <= Int64(Int.max) else { return [] }
        var result = [Float]()
        result.reserveCapacity(Int(range.count))
        for lag in range.minimum...range.maximum {
            if result.count.isMultiple(of: 2_048) {
                try Task.checkCancellation()
            }
            let overlap = context.overlap(at: lag)
            guard overlap.count > 0 else {
                result.append(0)
                continue
            }

            let numerator: Float
            switch implementation {
            case .direct:
                numerator = directNumerator(
                    reference: context.reference,
                    observed: context.observed,
                    overlap: overlap
                )
            case .fft:
                guard let fftNumerators else {
                    throw CorrelationAnalysisError.fftSetupFailure(length: 0)
                }
                let convolutionIndex = lag + Int64(context.reference.count - 1)
                numerator = fftNumerators.values[Int(convolutionIndex)]
            }

            switch context.configuration.normalization {
            case .none:
                result.append(numerator)
            case .overlapEnergy:
                let referenceEnergy = context.referenceEnergy(in: overlap.referenceRange)
                let observedEnergy = context.observedEnergy(in: overlap.observedRange)
                let denominator = sqrt(referenceEnergy * observedEnergy)
                if denominator > Double.leastNormalMagnitude {
                    let normalized = Double(numerator) / denominator
                    result.append(Float(max(-1, min(1, normalized))))
                } else {
                    result.append(0)
                }
            }
        }
        return result
    }

    private func directNumerator(
        reference: [Float],
        observed: [Float],
        overlap: CorrelationOverlap
    ) -> Float {
        var dot: Float = 0
        reference.withUnsafeBufferPointer { referenceBuffer in
            observed.withUnsafeBufferPointer { observedBuffer in
                guard let referenceBase = referenceBuffer.baseAddress,
                      let observedBase = observedBuffer.baseAddress else { return }
                vDSP_dotpr(
                    referenceBase.advanced(by: overlap.referenceRange.lowerBound),
                    1,
                    observedBase.advanced(by: overlap.observedRange.lowerBound),
                    1,
                    &dot,
                    vDSP_Length(overlap.count)
                )
            }
        }
        return dot
    }

    private func fftCorrelationNumerators(
        reference: [Float],
        observed: [Float]
    ) throws -> FFTNumerators {
        let (linearLength, overflow) = reference.count.addingReportingOverflow(observed.count - 1)
        guard !overflow else { throw CorrelationAnalysisError.fftLengthOverflow }
        let fftLength = try nextPowerOfTwo(atLeast: linearLength)
        try Task.checkCancellation()
        let convolution = try fftCache.correlateByConvolution(
            reference,
            observed,
            fftLength: fftLength,
            outputCount: linearLength
        )
        try Task.checkCancellation()
        return FFTNumerators(values: convolution, fftLength: fftLength)
    }

    private func nextPowerOfTwo(atLeast value: Int) throws -> Int {
        guard value > 0 else { return 1 }
        var result = 1
        while result < value {
            guard result <= Int.max / 2 else { throw CorrelationAnalysisError.fftLengthOverflow }
            result *= 2
        }
        return result
    }

    private func selectPeaks(
        values: [Float],
        firstLag: Int64,
        context: CorrelationContext
    ) throws -> (primaryIndex: Int, secondaryIndex: Int?) {
        var primaryIndex: Int?
        var primaryScore = -Double.infinity
        for index in values.indices {
            let score = selectionScore(values[index], selection: context.configuration.peakSelection)
            if score > primaryScore {
                primaryScore = score
                primaryIndex = index
            }
        }
        guard let primaryIndex, primaryScore.isFinite else {
            throw CorrelationAnalysisError.noPeakMatchingPolarity(context.configuration.peakSelection)
        }

        let primaryLag = firstLag + Int64(primaryIndex)
        var secondaryIndex: Int?
        var secondaryScore = -Double.infinity
        for index in values.indices {
            let lag = firstLag + Int64(index)
            if abs(lag - primaryLag) <= Int64(context.configuration.sidelobeExclusionRadius) {
                continue
            }
            let score = selectionScore(values[index], selection: context.configuration.peakSelection)
            if score > secondaryScore {
                secondaryScore = score
                secondaryIndex = index
            }
        }
        return (primaryIndex, secondaryIndex)
    }

    private func selectionScore(_ value: Float, selection: CorrelationPeakSelection) -> Double {
        switch selection {
        case .absolute:
            abs(Double(value))
        case .positive:
            value > 0 ? Double(value) : -.infinity
        case .negative:
            value < 0 ? -Double(value) : -.infinity
        }
    }

    private func interpolate(
        peakIndex: Int,
        values: [Float],
        selection: CorrelationPeakSelection,
        enabled: Bool
    ) -> (offset: Double?, status: SubsampleInterpolationStatus) {
        guard enabled else { return (nil, .disabledByConfiguration) }
        guard peakIndex > 0, peakIndex + 1 < values.count else {
            return (nil, .peakAtSequenceBoundary)
        }
        let left = selectionScore(values[peakIndex - 1], selection: selection)
        let center = selectionScore(values[peakIndex], selection: selection)
        let right = selectionScore(values[peakIndex + 1], selection: selection)
        guard left.isFinite, center.isFinite, right.isFinite else {
            return (nil, .degenerateNeighborhood)
        }
        let denominator = left - 2 * center + right
        guard denominator < -Double.ulpOfOne else {
            return (nil, .degenerateNeighborhood)
        }
        let offset = 0.5 * (left - right) / denominator
        guard offset.isFinite, abs(offset) <= 1 else {
            return (nil, .degenerateNeighborhood)
        }
        return (offset, .applied)
    }

    private func confidence(
        peakMagnitude: Double,
        ratio: Double,
        validity: DelayAnalysisValidity,
        configuration: CorrelationConfiguration
    ) -> Double {
        let denominator = max(Double.ulpOfOne, 1 - configuration.minimumPeakMagnitude)
        let peakQuality = max(0, min(1, (peakMagnitude - configuration.minimumPeakMagnitude) / denominator))
        let ratioDenominator = max(Double.ulpOfOne, configuration.minimumPeakToSidelobeRatio - 1)
        let ratioQuality = max(0, min(1, (ratio - 1) / ratioDenominator))
        let raw = 0.75 * peakQuality + 0.25 * ratioQuality
        switch validity {
        case .valid:
            return raw
        case .lowConfidence:
            return min(0.49, raw)
        case .ambiguous:
            return min(0.25, raw)
        }
    }

    private func estimatedWorkingSetBytes(
        context: CorrelationContext,
        implementation: CorrelationImplementation,
        fftLength: Int?,
        outputCount: Int
    ) -> Int64 {
        let prefixBytes = Int64(context.reference.count + context.observed.count + 2) * 8
        let resultBytes = Int64(context.searchedLagRange.count + Int64(outputCount)) * 4
        switch implementation {
        case .direct:
            return prefixBytes + resultBytes
        case .fft:
            return prefixBytes + resultBytes + Int64(fftLength ?? 0) * 8 * 4
        }
    }
}

public struct DelayAnalysisEngine: Sendable {
    private let correlationEngine: CorrelationEngine

    public init(correlationEngine: CorrelationEngine = .init()) {
        self.correlationEngine = correlationEngine
    }

    public func analyze(
        reference: AudioSampleBuffer,
        observed: AudioSampleBuffer,
        configuration: CorrelationConfiguration = .init()
    ) async throws -> DelayAnalysisResult {
        guard reference.format.sampleRate == observed.format.sampleRate else {
            throw CorrelationAnalysisError.sampleRateMismatch(
                reference: reference.format.sampleRate,
                observed: observed.format.sampleRate
            )
        }
        guard reference.channelCount == observed.channelCount else {
            throw CorrelationAnalysisError.channelCountMismatch(
                reference: reference.channelCount,
                observed: observed.channelCount
            )
        }
        guard (0..<reference.channelCount).contains(configuration.channel) else {
            throw CorrelationAnalysisError.invalidChannel(
                requested: configuration.channel,
                available: reference.channelCount
            )
        }

        let referenceChannel = try channelSamples(from: reference, channel: configuration.channel)
        let observedChannel = try channelSamples(from: observed, channel: configuration.channel)
        let correlation = try await correlationEngine.correlate(
            reference: referenceChannel,
            observed: observedChannel,
            configuration: configuration
        )
        guard let peak = correlation.primaryPeak, let diagnostics = correlation.diagnostics else {
            throw CorrelationAnalysisError.invalidConfiguration("The correlation engine returned no detailed peak data.")
        }
        let delay = DelayEstimate(
            sampleOffset: peak.lag,
            sampleRate: reference.format.sampleRate,
            confidence: correlation.confidence,
            fractionalSampleOffset: peak.fractionalLag,
            peakAmplitude: peak.value,
            peakToSidelobeRatio: correlation.peakToSidelobeRatio,
            isReliable: diagnostics.validity == .valid
        )
        return DelayAnalysisResult(delay: delay, correlation: correlation)
    }

    private func channelSamples(from buffer: AudioSampleBuffer, channel: Int) throws -> [Float] {
        if buffer.channelCount == 1 {
            // Swift Array copy-on-write shares the canonical mono storage with
            // the detached analysis task until a mutation occurs.
            return buffer.samples
        }
        return try buffer.withUnsafeChannelSamples(channel: channel) { Array($0) }
    }
}

/// Compatibility facade for the original Prompt 1 API. New code should use
/// `CorrelationEngine` or `DelayAnalysisEngine`.
public struct CrossCorrelationAnalyzer: Sendable {
    public init() {}

    public func analyze(reference: [Float], observed: [Float]) throws -> CorrelationResult {
        guard !reference.isEmpty, observed.count >= reference.count else {
            throw MeasurementError.correlationFailure(
                ErrorContext(diagnosticMessage: "Observed samples must contain the non-empty reference signal.")
            )
        }
        do {
            return try CorrelationEngine().correlateSynchronously(
                reference: reference,
                observed: observed,
                configuration: CorrelationConfiguration(
                    method: .direct,
                    searchRange: SampleLagRange(
                        minimum: 0,
                        maximum: Int64(observed.count - reference.count)
                    ),
                    sequenceOutput: .none,
                    minimumOverlapRatio: 1,
                    interpolateSubsample: false
                )
            )
        } catch let error as CorrelationAnalysisError {
            switch error {
            case .insufficientReferenceSignal, .insufficientObservedSignal:
                throw MeasurementError.insufficientSignal(
                    ErrorContext(diagnosticMessage: error.debugDescription)
                )
            default:
                throw MeasurementError.correlationFailure(
                    ErrorContext(diagnosticMessage: error.debugDescription)
                )
            }
        }
    }
}

private struct CorrelationOverlap {
    let referenceRange: Range<Int>
    let observedRange: Range<Int>
    var count: Int { referenceRange.count }
}

private struct CorrelationContext {
    let reference: [Float]
    let observed: [Float]
    let configuration: CorrelationConfiguration
    let referenceEnergyPrefix: [Double]
    let observedEnergyPrefix: [Double]
    let referenceRMS: Double
    let observedRMS: Double
    let fullLagRange: SampleLagRange
    let validLagRange: SampleLagRange
    let searchedLagRange: SampleLagRange
    let minimumOverlapCount: Int
    let searchRangeWasClamped: Bool

    init(
        reference: [Float],
        observed: [Float],
        configuration: CorrelationConfiguration
    ) throws {
        guard !reference.isEmpty else { throw CorrelationAnalysisError.emptyReference }
        guard !observed.isEmpty else { throw CorrelationAnalysisError.emptyObserved }
        if let index = reference.firstIndex(where: { !$0.isFinite }) {
            throw CorrelationAnalysisError.nonFiniteReference(index: index)
        }
        if let index = observed.firstIndex(where: { !$0.isFinite }) {
            throw CorrelationAnalysisError.nonFiniteObserved(index: index)
        }
        try Self.validate(configuration)

        let referenceRMS = Self.rms(reference)
        let observedRMS = Self.rms(observed)
        guard referenceRMS >= configuration.minimumInputRMS else {
            throw CorrelationAnalysisError.insufficientReferenceSignal(
                rms: referenceRMS,
                minimum: configuration.minimumInputRMS
            )
        }
        guard observedRMS >= configuration.minimumInputRMS else {
            throw CorrelationAnalysisError.insufficientObservedSignal(
                rms: observedRMS,
                minimum: configuration.minimumInputRMS
            )
        }

        let fullLagRange = SampleLagRange(
            minimum: -Int64(reference.count - 1),
            maximum: Int64(observed.count - 1)
        )
        let minimumOverlapCount = max(1, Int(ceil(Double(reference.count) * configuration.minimumOverlapRatio)))
        let maximumAvailable = min(reference.count, observed.count)
        guard minimumOverlapCount <= maximumAvailable else {
            throw CorrelationAnalysisError.insufficientOverlap(
                required: minimumOverlapCount,
                maximumAvailable: maximumAvailable
            )
        }

        var validMinimum = fullLagRange.minimum
        while Self.overlapCount(
            at: validMinimum,
            referenceCount: reference.count,
            observedCount: observed.count
        ) < minimumOverlapCount {
            validMinimum += 1
        }
        var validMaximum = fullLagRange.maximum
        while Self.overlapCount(
            at: validMaximum,
            referenceCount: reference.count,
            observedCount: observed.count
        ) < minimumOverlapCount {
            validMaximum -= 1
        }
        let validLagRange = SampleLagRange(minimum: validMinimum, maximum: validMaximum)
        let requested = configuration.searchRange ?? validLagRange
        guard requested.minimum <= requested.maximum else {
            throw CorrelationAnalysisError.invalidSearchRange(requested)
        }
        let searchedMinimum = max(requested.minimum, validLagRange.minimum)
        let searchedMaximum = min(requested.maximum, validLagRange.maximum)
        guard searchedMinimum <= searchedMaximum else {
            throw CorrelationAnalysisError.searchRangeOutsideValidLags(
                requested: requested,
                valid: validLagRange
            )
        }

        self.reference = reference
        self.observed = observed
        self.configuration = configuration
        referenceEnergyPrefix = Self.energyPrefix(reference)
        observedEnergyPrefix = Self.energyPrefix(observed)
        self.referenceRMS = referenceRMS
        self.observedRMS = observedRMS
        self.fullLagRange = fullLagRange
        self.validLagRange = validLagRange
        searchedLagRange = SampleLagRange(minimum: searchedMinimum, maximum: searchedMaximum)
        self.minimumOverlapCount = minimumOverlapCount
        searchRangeWasClamped = requested.minimum != searchedMinimum || requested.maximum != searchedMaximum
    }

    func overlap(at lag: Int64) -> CorrelationOverlap {
        let referenceStart = max(0, Int(-min(0, lag)))
        let referenceEnd = min(reference.count, observed.count - Int(lag))
        let observedStart = referenceStart + Int(lag)
        return CorrelationOverlap(
            referenceRange: referenceStart..<max(referenceStart, referenceEnd),
            observedRange: observedStart..<(observedStart + max(0, referenceEnd - referenceStart))
        )
    }

    func overlapCount(at lag: Int64) -> Int {
        Self.overlapCount(at: lag, referenceCount: reference.count, observedCount: observed.count)
    }

    func referenceEnergy(in range: Range<Int>) -> Double {
        referenceEnergyPrefix[range.upperBound] - referenceEnergyPrefix[range.lowerBound]
    }

    func observedEnergy(in range: Range<Int>) -> Double {
        observedEnergyPrefix[range.upperBound] - observedEnergyPrefix[range.lowerBound]
    }

    private static func overlapCount(at lag: Int64, referenceCount: Int, observedCount: Int) -> Int {
        let referenceStart = max(0, Int(-min(0, lag)))
        let referenceEnd = min(referenceCount, observedCount - Int(lag))
        return max(0, referenceEnd - referenceStart)
    }

    private static func energyPrefix(_ values: [Float]) -> [Double] {
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices {
            let value = Double(values[index])
            prefix[index + 1] = prefix[index] + value * value
        }
        return prefix
    }

    private static func rms(_ values: [Float]) -> Double {
        var result: Float = 0
        vDSP_rmsqv(values, 1, &result, vDSP_Length(values.count))
        return Double(result)
    }

    private static func validate(_ configuration: CorrelationConfiguration) throws {
        guard configuration.minimumOverlapRatio.isFinite,
              configuration.minimumOverlapRatio > 0,
              configuration.minimumOverlapRatio <= 1 else {
            throw CorrelationAnalysisError.invalidConfiguration("minimumOverlapRatio must be in (0, 1].")
        }
        guard configuration.directOperationLimit > 0 else {
            throw CorrelationAnalysisError.invalidConfiguration("directOperationLimit must be positive.")
        }
        guard configuration.sidelobeExclusionRadius >= 0 else {
            throw CorrelationAnalysisError.invalidConfiguration("sidelobeExclusionRadius must not be negative.")
        }
        guard configuration.minimumInputRMS.isFinite, configuration.minimumInputRMS >= 0 else {
            throw CorrelationAnalysisError.invalidConfiguration("minimumInputRMS must be finite and nonnegative.")
        }
        guard configuration.minimumPeakMagnitude.isFinite, configuration.minimumPeakMagnitude >= 0 else {
            throw CorrelationAnalysisError.invalidConfiguration("minimumPeakMagnitude must be finite and nonnegative.")
        }
        guard configuration.minimumPeakToSidelobeRatio.isFinite,
              configuration.minimumPeakToSidelobeRatio >= 1 else {
            throw CorrelationAnalysisError.invalidConfiguration("minimumPeakToSidelobeRatio must be finite and at least one.")
        }
        guard configuration.ambiguityTolerance.isFinite,
              configuration.ambiguityTolerance >= 0,
              configuration.ambiguityTolerance < 1 else {
            throw CorrelationAnalysisError.invalidConfiguration("ambiguityTolerance must be in [0, 1).")
        }
        if let range = configuration.searchRange, range.minimum > range.maximum {
            throw CorrelationAnalysisError.invalidSearchRange(range)
        }
    }
}

private struct FFTNumerators {
    let values: [Float]
    let fftLength: Int
}

private final class FFTSetupCache: @unchecked Sendable {
    private final class SetupPair {
        let forward: vDSP.DiscreteFourierTransform<Float>
        let inverse: vDSP.DiscreteFourierTransform<Float>

        init(length: Int) throws {
            do {
                forward = try vDSP.DiscreteFourierTransform<Float>(
                    count: length,
                    direction: .forward,
                    transformType: .complexComplex,
                    ofType: Float.self
                )
                inverse = try vDSP.DiscreteFourierTransform<Float>(
                    count: length,
                    direction: .inverse,
                    transformType: .complexComplex,
                    ofType: Float.self
                )
            } catch {
                throw CorrelationAnalysisError.fftSetupFailure(length: length)
            }
        }
    }

    private let lock = NSLock()
    private let maximumEntryCount: Int
    private var setups: [Int: SetupPair] = [:]
    private var accessOrder: [Int] = []

    init(maximumEntryCount: Int) {
        self.maximumEntryCount = maximumEntryCount
    }

    func correlateByConvolution(
        _ reference: [Float],
        _ second: [Float],
        fftLength: Int,
        outputCount: Int
    ) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let setup: SetupPair
        if let existing = setups[fftLength] {
            setup = existing
            accessOrder.removeAll { $0 == fftLength }
            accessOrder.append(fftLength)
        } else {
            setup = try SetupPair(length: fftLength)
            if setups.count >= maximumEntryCount, let oldest = accessOrder.first {
                setups.removeValue(forKey: oldest)
                accessOrder.removeFirst()
            }
            setups[fftLength] = setup
            accessOrder.append(fftLength)
        }

        var inputReal = [Float](repeating: 0, count: fftLength)
        let inputImaginary = [Float](repeating: 0, count: fftLength)
        for index in reference.indices {
            inputReal[reference.count - index - 1] = reference[index]
        }
        var firstReal = [Float](repeating: 0, count: fftLength)
        var firstImaginary = [Float](repeating: 0, count: fftLength)
        setup.forward.transform(
            inputReal: inputReal,
            inputImaginary: inputImaginary,
            outputReal: &firstReal,
            outputImaginary: &firstImaginary
        )

        for index in inputReal.indices { inputReal[index] = 0 }
        inputReal.replaceSubrange(0..<second.count, with: second)
        var secondReal = [Float](repeating: 0, count: fftLength)
        var secondImaginary = [Float](repeating: 0, count: fftLength)
        setup.forward.transform(
            inputReal: inputReal,
            inputImaginary: inputImaginary,
            outputReal: &secondReal,
            outputImaginary: &secondImaginary
        )

        for index in 0..<fftLength {
            let firstR = firstReal[index]
            let firstI = firstImaginary[index]
            let secondR = secondReal[index]
            let secondI = secondImaginary[index]
            firstReal[index] = firstR * secondR - firstI * secondI
            firstImaginary[index] = firstR * secondI + firstI * secondR
        }

        var resultReal = [Float](repeating: 0, count: fftLength)
        var resultImaginary = [Float](repeating: 0, count: fftLength)
        setup.inverse.transform(
            inputReal: firstReal,
            inputImaginary: firstImaginary,
            outputReal: &resultReal,
            outputImaginary: &resultImaginary
        )
        var scale = 1 / Float(fftLength)
        vDSP_vsmul(resultReal, 1, &scale, &resultReal, 1, vDSP_Length(resultReal.count))
        return Array(resultReal.prefix(outputCount))
    }
}
