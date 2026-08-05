import AudioLinkCore
import AudioLinkDSP
import Darwin
import Foundation

struct MeasurementVisualizationRenderer: Sendable {
    private let analysis: NewMeasurementAnalysis
    private let cache = MeasurementVisualizationCache()

    init(analysis: NewMeasurementAnalysis) {
        self.analysis = analysis
    }

    func initialWaveformViewport(alignment: WaveformAlignmentMode) -> PlotViewport {
        let delay = analysis.assessment.delay?.fractionalSampleOffset
            ?? analysis.assessment.delay.map { Double($0.sampleOffset.rawValue) }
            ?? 0
        let recordingOffset = alignment == .aligned ? -delay : 0
        let lower = min(0, recordingOffset)
        let referenceUpper = Double(max(0, analysis.preparedReference.frameCount - 1))
        let recordingUpper = recordingOffset + Double(max(0, analysis.preparedRecording.frameCount - 1))
        return PlotViewport(
            domainLowerBound: lower,
            domainUpperBound: max(referenceUpper, recordingUpper),
            minimumVisibleSpan: 8
        )
    }

    func initialCorrelationViewport() -> PlotViewport {
        if let sequence = analysis.assessment.correlation?.sequence {
            return PlotViewport(
                domainLowerBound: Double(sequence.firstLag),
                domainUpperBound: Double(sequence.lastLag),
                minimumVisibleSpan: 8
            )
        }
        return PlotViewport(domainLowerBound: 0, domainUpperBound: 0, minimumVisibleSpan: 0)
    }

    func waveform(
        viewport: PlotViewport,
        alignment: WaveformAlignmentMode,
        pixelWidth: Int
    ) async throws -> WaveformRenderData {
        let binBudget = Self.binBudget(for: pixelWidth)
        let key = WaveformCacheKey(
            alignment: alignment.rawValue,
            lower: viewport.visibleLowerBound.bitPattern,
            upper: viewport.visibleUpperBound.bitPattern,
            binBudget: binBudget
        )
        if let cached = await cache.waveform(for: key) { return cached }
        let analysis = self.analysis
        let prepared = try await Task.detached(priority: .userInitiated) {
            let result = try Self.makeWaveform(
                analysis: analysis,
                viewport: viewport,
                alignment: alignment,
                binBudget: binBudget
            )
            try Task.checkCancellation()
            return (result, Self.isExecutingOnMainThread())
        }.value
        await cache.store(prepared.0, for: key, preparedOnMainThread: prepared.1)
        return prepared.0
    }

    func correlation(
        viewport: PlotViewport,
        pixelWidth: Int
    ) async throws -> CorrelationRenderData {
        let binBudget = Self.binBudget(for: pixelWidth)
        let key = CorrelationCacheKey(
            lower: viewport.visibleLowerBound.bitPattern,
            upper: viewport.visibleUpperBound.bitPattern,
            binBudget: binBudget
        )
        if let cached = await cache.correlation(for: key) { return cached }
        let analysis = self.analysis
        let prepared = try await Task.detached(priority: .userInitiated) {
            let result = try Self.makeCorrelation(
                analysis: analysis,
                viewport: viewport,
                binBudget: binBudget
            )
            try Task.checkCancellation()
            return (result, Self.isExecutingOnMainThread())
        }.value
        await cache.store(prepared.0, for: key, preparedOnMainThread: prepared.1)
        return prepared.0
    }

    func peakDetail(selectedLag: Double? = nil) async throws -> PeakDetailRenderData {
        let analysis = self.analysis
        let prepared = try await Task.detached(priority: .userInitiated) {
            let result = try Self.makePeakDetail(analysis: analysis, selectedLag: selectedLag)
            try Task.checkCancellation()
            return (result, Self.isExecutingOnMainThread())
        }.value
        await cache.recordPreparation(preparedOnMainThread: prepared.1)
        return prepared.0
    }

    func lastPreparationWasOnMainThread() async -> Bool? {
        await cache.lastPreparationWasOnMainThread()
    }

    private static func makeWaveform(
        analysis: NewMeasurementAnalysis,
        viewport: PlotViewport,
        alignment: WaveformAlignmentMode,
        binBudget: Int
    ) throws -> WaveformRenderData {
        try Task.checkCancellation()
        let downsampler = PlotDataDownsampler()
        let delay = analysis.assessment.delay?.fractionalSampleOffset
            ?? analysis.assessment.delay.map { Double($0.sampleOffset.rawValue) }
        let alignedRecordingOffset = alignment == .aligned ? -(delay ?? 0) : 0
        let reference = analysis.preparedReference
        let recording = analysis.preparedRecording
        let referenceChannel = min(max(0, analysis.analysisChannel), max(0, reference.channelCount - 1))
        let recordingChannel = min(max(0, analysis.analysisChannel), max(0, recording.channelCount - 1))
        let referenceStorageStart = referenceChannel * reference.frameCount
        let recordingStorageStart = recordingChannel * recording.frameCount
        let referencePlotOffset = -Double(referenceStorageStart)
        let recordingPlotOffset = alignedRecordingOffset - Double(recordingStorageStart)
        let referenceRange = visibleStorageRange(
            frameCount: reference.frameCount,
            storageStart: referenceStorageStart,
            plotOffset: referencePlotOffset,
            viewport: viewport
        )
        let recordingRange = visibleStorageRange(
            frameCount: recording.frameCount,
            storageStart: recordingStorageStart,
            plotOffset: recordingPlotOffset,
            viewport: viewport
        )
        let referenceBins = downsampler.waveformEnvelope(
            samples: reference.audio.samples,
            sourceRange: referenceRange,
            plotOffsetSamples: referencePlotOffset,
            maximumBinCount: binBudget
        )
        try Task.checkCancellation()
        let recordingBins = downsampler.waveformEnvelope(
            samples: recording.audio.samples,
            sourceRange: recordingRange,
            plotOffsetSamples: recordingPlotOffset,
            maximumBinCount: binBudget
        )
        try Task.checkCancellation()
        let markerPosition = alignment == .aligned ? 0 : delay
        let markers = markerPosition.map {
            [
                PlotMarker(
                    id: "estimated-delay",
                    kind: .estimatedDelay,
                    position: $0,
                    label: alignment == .aligned ? "Aligned delay origin" : "Estimated delay"
                )
            ]
        } ?? []
        return WaveformRenderData(
            reference: WaveformTrackRenderData(
                title: "Reference",
                sampleRate: reference.sampleRate,
                sourceFrameCount: reference.frameCount,
                channelIndex: referenceChannel,
                plotOffsetSamples: referencePlotOffset,
                bins: referenceBins
            ),
            recording: WaveformTrackRenderData(
                title: "Recording",
                sampleRate: recording.sampleRate,
                sourceFrameCount: recording.frameCount,
                channelIndex: recordingChannel,
                plotOffsetSamples: recordingPlotOffset,
                bins: recordingBins
            ),
            viewport: viewport,
            alignmentMode: alignment,
            estimatedDelaySamples: delay,
            markers: markers
        )
    }

    private static func makeCorrelation(
        analysis: NewMeasurementAnalysis,
        viewport: PlotViewport,
        binBudget: Int
    ) throws -> CorrelationRenderData {
        try Task.checkCancellation()
        let sampleRate = analysis.preparedReference.sampleRate
        guard let correlation = analysis.assessment.correlation,
              let sequence = correlation.sequence else {
            return CorrelationRenderData(
                sampleRate: sampleRate,
                viewport: viewport,
                bins: [],
                markers: [],
                searchRange: SampleLagRange(minimum: 0, maximum: 0),
                confidenceThresholdMagnitude: MeasurementQualityThresholds.standard.minimumUsableCorrelation,
                peakAtSearchBoundary: false
            )
        }
        let visibleLower = max(sequence.firstLag, Int64(floor(viewport.visibleLowerBound)))
        let visibleUpper = min(sequence.lastLag, Int64(ceil(viewport.visibleUpperBound)))
        let range = visibleLower <= visibleUpper ? visibleLower...visibleUpper : sequence.firstLag...sequence.firstLag
        let bins = PlotDataDownsampler().correlationEnvelope(
            values: sequence.values,
            firstLag: sequence.firstLag,
            lagRange: range,
            maximumBinCount: binBudget
        )
        try Task.checkCancellation()
        let candidates = analysis.assessment.quality.peakAmbiguity.candidates
        var markers: [PlotMarker] = []
        var usedLags = Set<Int64>()
        if let primary = correlation.primaryPeak {
            usedLags.insert(primary.lag.rawValue)
            markers.append(marker(for: primary, kind: .primaryPeak, id: "primary", label: "Primary peak"))
        }
        if let secondary = correlation.secondaryPeak,
           usedLags.insert(secondary.lag.rawValue).inserted {
            markers.append(marker(for: secondary, kind: .secondaryPeak, id: "secondary", label: "Secondary peak"))
        }
        for (index, candidate) in candidates.enumerated()
        where usedLags.insert(candidate.lag.rawValue).inserted {
            markers.append(
                marker(
                    for: candidate,
                    kind: .candidatePeak,
                    id: "candidate-\(index)",
                    label: "Candidate \(index + 1)"
                )
            )
        }
        let diagnostics = correlation.diagnostics
        let searchedRange = diagnostics?.searchedLagRange
            ?? SampleLagRange(minimum: sequence.firstLag, maximum: sequence.lastLag)
        markers.append(
            PlotMarker(
                id: "search-minimum",
                kind: .searchBoundary,
                position: Double(searchedRange.minimum),
                label: "Search minimum"
            )
        )
        markers.append(
            PlotMarker(
                id: "search-maximum",
                kind: .searchBoundary,
                position: Double(searchedRange.maximum),
                label: "Search maximum"
            )
        )
        let threshold = MeasurementQualityThresholds.standard.minimumUsableCorrelation
        markers.append(
            PlotMarker(
                id: "positive-confidence-threshold",
                kind: .confidenceThreshold,
                position: Double(searchedRange.minimum),
                value: threshold,
                label: "Usable correlation threshold"
            )
        )
        markers.append(
            PlotMarker(
                id: "negative-confidence-threshold",
                kind: .confidenceThreshold,
                position: Double(searchedRange.minimum),
                value: -threshold,
                label: "Negative threshold"
            )
        )
        return CorrelationRenderData(
            sampleRate: sampleRate,
            viewport: viewport,
            bins: bins,
            markers: markers,
            searchRange: searchedRange,
            confidenceThresholdMagnitude: threshold,
            peakAtSearchBoundary: diagnostics?.peakAtSearchBoundary ?? false
        )
    }

    private static func makePeakDetail(
        analysis: NewMeasurementAnalysis,
        selectedLag: Double?
    ) throws -> PeakDetailRenderData {
        try Task.checkCancellation()
        let sampleRate = analysis.preparedReference.sampleRate
        guard let correlation = analysis.assessment.correlation,
              let sequence = correlation.sequence,
              let primary = correlation.primaryPeak else {
            return PeakDetailRenderData(
                sampleRate: sampleRate,
                viewport: PlotViewport(domainLowerBound: 0, domainUpperBound: 0, minimumVisibleSpan: 0),
                samples: [],
                interpolationCurve: [],
                integerPeakLag: 0,
                fractionalPeakLag: nil,
                peakWidthSamples: nil,
                localNoiseFloor: 0,
                markers: [],
                confidenceMetrics: []
            )
        }
        let candidates = analysis.assessment.quality.peakAmbiguity.candidates
        let selectedPeak = selectedLag.flatMap { requested in
            candidates.min { abs(Double($0.lag.rawValue) - requested) < abs(Double($1.lag.rawValue) - requested) }
        } ?? primary
        let centerIndex = Int(selectedPeak.lag.rawValue - sequence.firstLag)
        let peakWidth = selectedPeak.lag == primary.lag
            ? analysis.assessment.quality.delayDiagnostics.peakWidthSamples
            : nil
        let halfWindow = min(128, max(16, Int(ceil((peakWidth ?? 8) * 3))))
        let lowerIndex = max(0, centerIndex - halfWindow)
        let upperIndex = min(sequence.values.count - 1, centerIndex + halfWindow)
        let points = guardSafePoints(
            values: sequence.values,
            firstLag: sequence.firstLag,
            range: lowerIndex...upperIndex
        )
        let interpolation = interpolationCurve(
            values: sequence.values,
            firstLag: sequence.firstLag,
            peakIndex: centerIndex,
            fractionalLag: selectedPeak.fractionalLag
        )
        var noiseEnergy = 0.0
        var noiseCount = 0
        for index in lowerIndex...upperIndex where abs(index - centerIndex) > 4 {
            let value = Double(sequence.values[index])
            noiseEnergy += value * value
            noiseCount += 1
        }
        let noiseFloor = noiseCount > 0 ? sqrt(noiseEnergy / Double(noiseCount)) : 0
        var markers = [
            PlotMarker(
                id: "integer-peak",
                kind: .integerPeak,
                position: Double(selectedPeak.lag.rawValue),
                value: selectedPeak.value,
                label: "Integer peak"
            )
        ]
        if let fractionalLag = selectedPeak.fractionalLag {
            markers.append(
                PlotMarker(
                    id: "fractional-peak",
                    kind: .fractionalPeak,
                    position: fractionalLag,
                    value: interpolationValue(at: fractionalLag, curve: interpolation),
                    label: "Interpolated peak"
                )
            )
        }
        let viewport = PlotViewport(
            domainLowerBound: Double(sequence.firstLag + Int64(lowerIndex)),
            domainUpperBound: Double(sequence.firstLag + Int64(upperIndex)),
            minimumVisibleSpan: 2
        )
        return PeakDetailRenderData(
            sampleRate: sampleRate,
            viewport: viewport,
            samples: points,
            interpolationCurve: interpolation,
            integerPeakLag: selectedPeak.lag.rawValue,
            fractionalPeakLag: selectedPeak.fractionalLag,
            peakWidthSamples: peakWidth,
            localNoiseFloor: noiseFloor,
            markers: markers,
            confidenceMetrics: peakMetrics(analysis: analysis, peak: selectedPeak, noiseFloor: noiseFloor)
        )
    }

    private static func visibleStorageRange(
        frameCount: Int,
        storageStart: Int,
        plotOffset: Double,
        viewport: PlotViewport
    ) -> Range<Int> {
        guard frameCount > 0 else { return storageStart..<storageStart }
        let sourceLower = Int(floor(viewport.visibleLowerBound - plotOffset))
        let sourceUpper = Int(ceil(viewport.visibleUpperBound - plotOffset)) + 1
        let storageEnd = storageStart + frameCount
        let lower = min(max(sourceLower, storageStart), storageEnd)
        let upper = min(max(sourceUpper, lower), storageEnd)
        return lower..<upper
    }

    private static func marker(
        for peak: CorrelationPeak,
        kind: PlotMarkerKind,
        id: String,
        label: String
    ) -> PlotMarker {
        PlotMarker(
            id: id,
            kind: kind,
            position: peak.fractionalLag ?? Double(peak.lag.rawValue),
            value: peak.value,
            label: label
        )
    }

    private static func guardSafePoints(
        values: [Float],
        firstLag: Int64,
        range: ClosedRange<Int>
    ) -> [PeakDetailPoint] {
        guard !values.isEmpty else { return [] }
        return range.map { index in
            PeakDetailPoint(lag: Double(firstLag + Int64(index)), value: Double(values[index]))
        }
    }

    private static func interpolationCurve(
        values: [Float],
        firstLag: Int64,
        peakIndex: Int,
        fractionalLag: Double?
    ) -> [PeakDetailPoint] {
        guard fractionalLag != nil,
              peakIndex > 0,
              peakIndex + 1 < values.count else { return [] }
        let left = Double(values[peakIndex - 1])
        let center = Double(values[peakIndex])
        let right = Double(values[peakIndex + 1])
        let quadratic = (left + right - 2 * center) / 2
        let linear = (right - left) / 2
        let integerLag = Double(firstLag + Int64(peakIndex))
        return (0...64).map { step in
            let offset = -1 + 2 * Double(step) / 64
            return PeakDetailPoint(
                lag: integerLag + offset,
                value: quadratic * offset * offset + linear * offset + center
            )
        }
    }

    private static func interpolationValue(at lag: Double, curve: [PeakDetailPoint]) -> Double? {
        curve.min { abs($0.lag - lag) < abs($1.lag - lag) }?.value
    }

    private static func peakMetrics(
        analysis: NewMeasurementAnalysis,
        peak: CorrelationPeak,
        noiseFloor: Double
    ) -> [PeakDetailMetric] {
        let quality = analysis.assessment.quality
        let byCode = Dictionary(uniqueKeysWithValues: quality.metrics.map { ($0.code, $0.value) })
        var metrics = [
            PeakDetailMetric(id: "correlation", title: "Peak correlation", value: peak.value, unit: "coefficient"),
            PeakDetailMetric(id: "noise-floor", title: "Local noise floor", value: noiseFloor, unit: "RMS"),
            PeakDetailMetric(id: "confidence", title: "Confidence", value: quality.confidence.value, unit: "fraction")
        ]
        let optionalMetrics: [(QualityMetricCode, String, String)] = [
            (.primaryToSecondaryRatio, "Primary / secondary", "ratio"),
            (.peakToSidelobeRatio, "Peak / sidelobe", "ratio"),
            (.localPeakSharpness, "Local sharpness", "fraction"),
            (.peakWidthSamples, "Peak width", "samples"),
            (.signalToNoiseDecibels, "Estimated SNR", "dB")
        ]
        for (code, title, unit) in optionalMetrics {
            if let value = byCode[code] {
                metrics.append(PeakDetailMetric(id: code.rawValue, title: title, value: value, unit: unit))
            }
        }
        return metrics
    }

    private static func binBudget(for pixelWidth: Int) -> Int {
        let requested = min(4_096, max(64, pixelWidth * 2))
        var powerOfTwo = 64
        while powerOfTwo < requested { powerOfTwo *= 2 }
        return min(4_096, powerOfTwo)
    }

    private static func isExecutingOnMainThread() -> Bool {
        pthread_main_np() != 0
    }
}

private struct WaveformCacheKey: Hashable, Sendable {
    let alignment: String
    let lower: UInt64
    let upper: UInt64
    let binBudget: Int
}

private struct CorrelationCacheKey: Hashable, Sendable {
    let lower: UInt64
    let upper: UInt64
    let binBudget: Int
}

private actor MeasurementVisualizationCache {
    private let capacity = 12
    private var waveforms: [WaveformCacheKey: WaveformRenderData] = [:]
    private var waveformOrder: [WaveformCacheKey] = []
    private var correlations: [CorrelationCacheKey: CorrelationRenderData] = [:]
    private var correlationOrder: [CorrelationCacheKey] = []
    private var preparationThreadHistory: [Bool] = []

    func waveform(for key: WaveformCacheKey) -> WaveformRenderData? {
        waveforms[key]
    }

    func correlation(for key: CorrelationCacheKey) -> CorrelationRenderData? {
        correlations[key]
    }

    func store(
        _ data: WaveformRenderData,
        for key: WaveformCacheKey,
        preparedOnMainThread: Bool
    ) {
        if waveforms[key] == nil { waveformOrder.append(key) }
        waveforms[key] = data
        trim(&waveforms, order: &waveformOrder)
        recordPreparation(preparedOnMainThread: preparedOnMainThread)
    }

    func store(
        _ data: CorrelationRenderData,
        for key: CorrelationCacheKey,
        preparedOnMainThread: Bool
    ) {
        if correlations[key] == nil { correlationOrder.append(key) }
        correlations[key] = data
        trim(&correlations, order: &correlationOrder)
        recordPreparation(preparedOnMainThread: preparedOnMainThread)
    }

    func recordPreparation(preparedOnMainThread: Bool) {
        preparationThreadHistory.append(preparedOnMainThread)
        if preparationThreadHistory.count > capacity {
            preparationThreadHistory.removeFirst(preparationThreadHistory.count - capacity)
        }
    }

    func lastPreparationWasOnMainThread() -> Bool? {
        preparationThreadHistory.last
    }

    private func trim<Key: Hashable, Value>(
        _ dictionary: inout [Key: Value],
        order: inout [Key]
    ) {
        while order.count > capacity {
            dictionary.removeValue(forKey: order.removeFirst())
        }
    }
}
