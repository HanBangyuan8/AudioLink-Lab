import AudioLinkCore
import AudioLinkDSP
import Testing

@Test
func waveformEnvelopeRetainsLocalExtremaExactly() {
    var samples = [Float](repeating: 0.05, count: 10_000)
    samples[1_234] = 0.97
    samples[7_654] = -0.91

    let bins = PlotDataDownsampler().waveformEnvelope(
        samples: samples,
        maximumBinCount: 100
    )

    #expect(bins.count == 100)
    #expect(bins.contains { $0.maximum == 0.97 })
    #expect(bins.contains { $0.minimum == -0.91 })
    #expect(bins.allSatisfy { $0.minimum <= $0.maximum })
}

@Test
func correlationEnvelopePreservesSignedAndAbsolutePeaks() {
    var values = [Float](repeating: 0.01, count: 4_096)
    values[511] = 0.82
    values[3_777] = -0.96
    let firstLag: Int64 = -2_000

    let bins = PlotDataDownsampler().correlationEnvelope(
        values: values,
        firstLag: firstLag,
        maximumBinCount: 64
    )

    #expect(bins.contains { $0.maximum == 0.82 })
    #expect(bins.contains { $0.minimum == -0.96 })
    #expect(bins.contains { $0.strongestLag == firstLag + 3_777 && $0.strongestValue == -0.96 })
}

@Test
func viewportCoordinateConversionZoomAndPanAreBounded() {
    let viewport = PlotViewport(
        domainLowerBound: -1_000,
        domainUpperBound: 3_000,
        visibleLowerBound: 0,
        visibleUpperBound: 2_000,
        minimumVisibleSpan: 8
    )
    #expect(viewport.value(atNormalizedPosition: 0.25) == 500)
    #expect(viewport.normalizedPosition(for: 1_500) == 0.75)

    let zoomed = viewport.zoomed(by: 2, anchorNormalized: 0.25)
    #expect(zoomed.visibleSpan == 1_000)
    #expect(zoomed.value(atNormalizedPosition: 0.25) == 500)

    let leftClamped = zoomed.panned(by: -10_000)
    #expect(leftClamped.visibleLowerBound == -1_000)
    let rightClamped = zoomed.panned(by: 10_000)
    #expect(rightClamped.visibleUpperBound == 3_000)
}

@Test
func sampleAndTimeCoordinatesUseExplicitSampleRate() throws {
    let rate = try SampleRate(hertz: 48_000)
    let emptyTrack = WaveformTrackRenderData(
        title: "Reference",
        sampleRate: rate,
        sourceFrameCount: 0,
        channelIndex: 0,
        plotOffsetSamples: 0,
        bins: []
    )
    let data = WaveformRenderData(
        reference: emptyTrack,
        recording: emptyTrack,
        viewport: PlotViewport(domainLowerBound: 0, domainUpperBound: 96_000),
        alignmentMode: .unaligned,
        estimatedDelaySamples: nil,
        markers: []
    )

    #expect(data.samplePosition(atNormalizedPosition: 0.5) == 48_000)
    #expect(data.timeSeconds(atSamplePosition: 48_000) == 1)
}

@Test
func downsamplingIsSafeForEmptyAndSingleSampleInputs() {
    let downsampler = PlotDataDownsampler()
    #expect(downsampler.waveformEnvelope(samples: [], maximumBinCount: 100).isEmpty)
    #expect(downsampler.correlationEnvelope(values: [], firstLag: 0, maximumBinCount: 100).isEmpty)

    let waveform = downsampler.waveformEnvelope(samples: [0.4], maximumBinCount: 100)
    #expect(waveform.count == 1)
    #expect(waveform[0].minimum == 0.4)
    #expect(waveform[0].maximum == 0.4)

    let correlation = downsampler.correlationEnvelope(values: [-0.7], firstLag: -3, maximumBinCount: 100)
    #expect(correlation.count == 1)
    #expect(correlation[0].strongestLag == -3)
    #expect(correlation[0].strongestValue == -0.7)
}
