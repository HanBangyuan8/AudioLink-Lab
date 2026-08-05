import AudioLinkCore
import Foundation

public enum DownsamplingStrategy: String, Codable, CaseIterable, Sendable {
    /// One output bin represents the minimum and maximum sample in its source interval.
    case minMaxEnvelope
    /// Correlation bins retain signed extrema and the strongest absolute sample.
    case peakPreserving
}

public enum PlotMarkerKind: String, Codable, CaseIterable, Sendable {
    case estimatedDelay
    case primaryPeak
    case secondaryPeak
    case candidatePeak
    case integerPeak
    case fractionalPeak
    case searchBoundary
    case confidenceThreshold
    case cursor
}

public struct PlotMarker: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: PlotMarkerKind
    public let position: Double
    public let value: Double?
    public let label: String

    public init(
        id: String,
        kind: PlotMarkerKind,
        position: Double,
        value: Double? = nil,
        label: String
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.value = value
        self.label = label
    }
}

public struct PlotViewport: Codable, Equatable, Sendable {
    public let domainLowerBound: Double
    public let domainUpperBound: Double
    public let visibleLowerBound: Double
    public let visibleUpperBound: Double
    public let minimumVisibleSpan: Double

    public init(
        domainLowerBound: Double,
        domainUpperBound: Double,
        visibleLowerBound: Double? = nil,
        visibleUpperBound: Double? = nil,
        minimumVisibleSpan: Double = 1
    ) {
        let finiteLower = domainLowerBound.isFinite ? domainLowerBound : 0
        let finiteUpper = domainUpperBound.isFinite ? domainUpperBound : finiteLower
        let lower = min(finiteLower, finiteUpper)
        let upper = max(finiteLower, finiteUpper)
        let domainSpan = upper - lower
        let sanitizedMinimumSpan = min(
            domainSpan,
            max(0, minimumVisibleSpan.isFinite ? minimumVisibleSpan : 0)
        )
        let requestedLower = visibleLowerBound?.isFinite == true ? visibleLowerBound ?? lower : lower
        let requestedUpper = visibleUpperBound?.isFinite == true ? visibleUpperBound ?? upper : upper
        let orderedVisibleLower = min(requestedLower, requestedUpper)
        let orderedVisibleUpper = max(requestedLower, requestedUpper)
        let requestedSpan = max(sanitizedMinimumSpan, orderedVisibleUpper - orderedVisibleLower)
        let clampedSpan = min(domainSpan, requestedSpan)
        let center = (orderedVisibleLower + orderedVisibleUpper) / 2
        let unclampedLower = center - clampedSpan / 2
        let clampedLower = min(max(unclampedLower, lower), upper - clampedSpan)

        self.domainLowerBound = lower
        self.domainUpperBound = upper
        self.visibleLowerBound = clampedLower
        self.visibleUpperBound = clampedLower + clampedSpan
        self.minimumVisibleSpan = sanitizedMinimumSpan
    }

    public var domainSpan: Double { domainUpperBound - domainLowerBound }
    public var visibleSpan: Double { visibleUpperBound - visibleLowerBound }

    public func value(atNormalizedPosition normalizedPosition: Double) -> Double {
        guard visibleSpan > 0 else { return visibleLowerBound }
        let clamped = min(1, max(0, normalizedPosition.isFinite ? normalizedPosition : 0))
        return visibleLowerBound + clamped * visibleSpan
    }

    public func normalizedPosition(for value: Double) -> Double {
        guard visibleSpan > 0, value.isFinite else { return 0 }
        return min(1, max(0, (value - visibleLowerBound) / visibleSpan))
    }

    /// A factor above one zooms in; below one zooms out.
    public func zoomed(by factor: Double, anchorNormalized: Double = 0.5) -> PlotViewport {
        guard factor.isFinite, factor > 0, domainSpan > 0 else { return self }
        let anchor = min(1, max(0, anchorNormalized.isFinite ? anchorNormalized : 0.5))
        let anchorValue = value(atNormalizedPosition: anchor)
        let nextSpan = min(domainSpan, max(minimumVisibleSpan, visibleSpan / factor))
        let requestedLower = anchorValue - nextSpan * anchor
        return PlotViewport(
            domainLowerBound: domainLowerBound,
            domainUpperBound: domainUpperBound,
            visibleLowerBound: requestedLower,
            visibleUpperBound: requestedLower + nextSpan,
            minimumVisibleSpan: minimumVisibleSpan
        )
    }

    public func panned(by delta: Double) -> PlotViewport {
        guard delta.isFinite, domainSpan > 0 else { return self }
        return PlotViewport(
            domainLowerBound: domainLowerBound,
            domainUpperBound: domainUpperBound,
            visibleLowerBound: visibleLowerBound + delta,
            visibleUpperBound: visibleUpperBound + delta,
            minimumVisibleSpan: minimumVisibleSpan
        )
    }
}

public struct WaveformEnvelopeBin: Codable, Equatable, Sendable {
    public let firstSamplePosition: Double
    public let lastSamplePosition: Double
    public let minimum: Float
    public let maximum: Float

    public init(
        firstSamplePosition: Double,
        lastSamplePosition: Double,
        minimum: Float,
        maximum: Float
    ) {
        self.firstSamplePosition = firstSamplePosition
        self.lastSamplePosition = lastSamplePosition
        self.minimum = minimum
        self.maximum = maximum
    }

    public var centerSamplePosition: Double {
        (firstSamplePosition + lastSamplePosition) / 2
    }
}

public struct WaveformTrackRenderData: Codable, Equatable, Sendable {
    public let title: String
    public let sampleRate: SampleRate
    public let sourceFrameCount: Int
    public let channelIndex: Int
    public let plotOffsetSamples: Double
    public let bins: [WaveformEnvelopeBin]

    public init(
        title: String,
        sampleRate: SampleRate,
        sourceFrameCount: Int,
        channelIndex: Int,
        plotOffsetSamples: Double,
        bins: [WaveformEnvelopeBin]
    ) {
        self.title = title
        self.sampleRate = sampleRate
        self.sourceFrameCount = sourceFrameCount
        self.channelIndex = channelIndex
        self.plotOffsetSamples = plotOffsetSamples
        self.bins = bins
    }
}

public enum WaveformAlignmentMode: String, Codable, CaseIterable, Sendable {
    case unaligned
    case aligned
}

public struct WaveformRenderData: Codable, Equatable, Sendable {
    public let reference: WaveformTrackRenderData
    public let recording: WaveformTrackRenderData
    public let viewport: PlotViewport
    public let alignmentMode: WaveformAlignmentMode
    public let estimatedDelaySamples: Double?
    public let markers: [PlotMarker]
    public let downsamplingStrategy: DownsamplingStrategy

    public init(
        reference: WaveformTrackRenderData,
        recording: WaveformTrackRenderData,
        viewport: PlotViewport,
        alignmentMode: WaveformAlignmentMode,
        estimatedDelaySamples: Double?,
        markers: [PlotMarker],
        downsamplingStrategy: DownsamplingStrategy = .minMaxEnvelope
    ) {
        self.reference = reference
        self.recording = recording
        self.viewport = viewport
        self.alignmentMode = alignmentMode
        self.estimatedDelaySamples = estimatedDelaySamples
        self.markers = markers
        self.downsamplingStrategy = downsamplingStrategy
    }

    public func samplePosition(atNormalizedPosition position: Double) -> Double {
        viewport.value(atNormalizedPosition: position)
    }

    public func timeSeconds(atSamplePosition samplePosition: Double) -> Double {
        samplePosition / reference.sampleRate.hertz
    }
}

public struct CorrelationEnvelopeBin: Codable, Equatable, Sendable {
    public let firstLag: Int64
    public let lastLag: Int64
    public let minimum: Float
    public let maximum: Float
    public let strongestLag: Int64
    public let strongestValue: Float

    public init(
        firstLag: Int64,
        lastLag: Int64,
        minimum: Float,
        maximum: Float,
        strongestLag: Int64,
        strongestValue: Float
    ) {
        self.firstLag = firstLag
        self.lastLag = lastLag
        self.minimum = minimum
        self.maximum = maximum
        self.strongestLag = strongestLag
        self.strongestValue = strongestValue
    }
}

public struct CorrelationRenderData: Codable, Equatable, Sendable {
    public let sampleRate: SampleRate
    public let viewport: PlotViewport
    public let bins: [CorrelationEnvelopeBin]
    public let markers: [PlotMarker]
    public let searchRange: SampleLagRange
    public let confidenceThresholdMagnitude: Double
    public let peakAtSearchBoundary: Bool
    public let downsamplingStrategy: DownsamplingStrategy

    public init(
        sampleRate: SampleRate,
        viewport: PlotViewport,
        bins: [CorrelationEnvelopeBin],
        markers: [PlotMarker],
        searchRange: SampleLagRange,
        confidenceThresholdMagnitude: Double,
        peakAtSearchBoundary: Bool,
        downsamplingStrategy: DownsamplingStrategy = .peakPreserving
    ) {
        self.sampleRate = sampleRate
        self.viewport = viewport
        self.bins = bins
        self.markers = markers
        self.searchRange = searchRange
        self.confidenceThresholdMagnitude = confidenceThresholdMagnitude
        self.peakAtSearchBoundary = peakAtSearchBoundary
        self.downsamplingStrategy = downsamplingStrategy
    }

    public func lag(atNormalizedPosition position: Double) -> Double {
        viewport.value(atNormalizedPosition: position)
    }

    public func milliseconds(forLag lag: Double) -> Double {
        lag / sampleRate.hertz * 1_000
    }
}

public struct PeakDetailPoint: Codable, Equatable, Sendable {
    public let lag: Double
    public let value: Double

    public init(lag: Double, value: Double) {
        self.lag = lag
        self.value = value
    }
}

public struct PeakDetailMetric: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let value: Double
    public let unit: String

    public init(id: String, title: String, value: Double, unit: String) {
        self.id = id
        self.title = title
        self.value = value
        self.unit = unit
    }
}

public struct PeakDetailRenderData: Codable, Equatable, Sendable {
    public let sampleRate: SampleRate
    public let viewport: PlotViewport
    public let samples: [PeakDetailPoint]
    public let interpolationCurve: [PeakDetailPoint]
    public let integerPeakLag: Int64
    public let fractionalPeakLag: Double?
    public let peakWidthSamples: Double?
    public let localNoiseFloor: Double
    public let markers: [PlotMarker]
    public let confidenceMetrics: [PeakDetailMetric]

    public init(
        sampleRate: SampleRate,
        viewport: PlotViewport,
        samples: [PeakDetailPoint],
        interpolationCurve: [PeakDetailPoint],
        integerPeakLag: Int64,
        fractionalPeakLag: Double?,
        peakWidthSamples: Double?,
        localNoiseFloor: Double,
        markers: [PlotMarker],
        confidenceMetrics: [PeakDetailMetric]
    ) {
        self.sampleRate = sampleRate
        self.viewport = viewport
        self.samples = samples
        self.interpolationCurve = interpolationCurve
        self.integerPeakLag = integerPeakLag
        self.fractionalPeakLag = fractionalPeakLag
        self.peakWidthSamples = peakWidthSamples
        self.localNoiseFloor = localNoiseFloor
        self.markers = markers
        self.confidenceMetrics = confidenceMetrics
    }
}

public struct PlotDataDownsampler: Sendable {
    public init() {}

    public func waveformEnvelope(
        samples: [Float],
        sourceRange: Range<Int>? = nil,
        plotOffsetSamples: Double = 0,
        maximumBinCount: Int
    ) -> [WaveformEnvelopeBin] {
        guard !samples.isEmpty, maximumBinCount > 0 else { return [] }
        let requested = sourceRange ?? samples.startIndex..<samples.endIndex
        let lower = min(max(requested.lowerBound, samples.startIndex), samples.endIndex)
        let upper = min(max(requested.upperBound, lower), samples.endIndex)
        guard lower < upper else { return [] }
        let sourceCount = upper - lower
        let binCount = min(sourceCount, maximumBinCount)
        var result: [WaveformEnvelopeBin] = []
        result.reserveCapacity(binCount)

        for bin in 0..<binCount {
            let start = lower + bin * sourceCount / binCount
            let end = lower + (bin + 1) * sourceCount / binCount
            var minimum = Float.infinity
            var maximum = -Float.infinity
            for index in start..<end {
                if index.isMultiple(of: 8_192), Task.isCancelled { return [] }
                let sample = samples[index]
                minimum = min(minimum, sample)
                maximum = max(maximum, sample)
            }
            result.append(
                WaveformEnvelopeBin(
                    firstSamplePosition: Double(start) + plotOffsetSamples,
                    lastSamplePosition: Double(max(start, end - 1)) + plotOffsetSamples,
                    minimum: minimum,
                    maximum: maximum
                )
            )
        }
        return result
    }

    public func correlationEnvelope(
        values: [Float],
        firstLag: Int64,
        lagRange: ClosedRange<Int64>? = nil,
        maximumBinCount: Int
    ) -> [CorrelationEnvelopeBin] {
        guard !values.isEmpty, maximumBinCount > 0 else { return [] }
        let sequenceLastLag = firstLag + Int64(values.count) - 1
        let requestedLower = lagRange?.lowerBound ?? firstLag
        let requestedUpper = lagRange?.upperBound ?? sequenceLastLag
        let lowerLag = min(max(requestedLower, firstLag), sequenceLastLag)
        let upperLag = min(max(requestedUpper, lowerLag), sequenceLastLag)
        let lowerIndex = Int(lowerLag - firstLag)
        let upperIndexExclusive = Int(upperLag - firstLag) + 1
        let sourceCount = upperIndexExclusive - lowerIndex
        let binCount = min(sourceCount, maximumBinCount)
        var result: [CorrelationEnvelopeBin] = []
        result.reserveCapacity(binCount)

        for bin in 0..<binCount {
            let start = lowerIndex + bin * sourceCount / binCount
            let end = lowerIndex + (bin + 1) * sourceCount / binCount
            var minimum = Float.infinity
            var maximum = -Float.infinity
            var strongestValue: Float = 0
            var strongestIndex = start
            for index in start..<end {
                if index.isMultiple(of: 8_192), Task.isCancelled { return [] }
                let value = values[index]
                minimum = min(minimum, value)
                maximum = max(maximum, value)
                if abs(value) > abs(strongestValue) {
                    strongestValue = value
                    strongestIndex = index
                }
            }
            result.append(
                CorrelationEnvelopeBin(
                    firstLag: firstLag + Int64(start),
                    lastLag: firstLag + Int64(max(start, end - 1)),
                    minimum: minimum,
                    maximum: maximum,
                    strongestLag: firstLag + Int64(strongestIndex),
                    strongestValue: strongestValue
                )
            )
        }
        return result
    }
}
