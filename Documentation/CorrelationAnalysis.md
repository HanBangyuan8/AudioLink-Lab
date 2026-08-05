# Delay and correlation analysis

AudioLinkDSP estimates delay with linear cross-correlation. The implementation
is independent of SwiftUI and accepts either Float arrays through
`CorrelationEngine` or canonical `AudioSampleBuffer` values through
`DelayAnalysisEngine`.

## Definition and lag convention

Let the reference be `x[0 ... M-1]` and the recording be `y[0 ... N-1]`.
AudioLink defines raw cross-correlation as

```text
rxy[l] = sum x[i] y[i + l]
```

where the sum includes only indices for which both `i` and `i + l` exist. The
complete linear lag range is

```text
-(M - 1) ... (N - 1)
```

Consequences of the input order are intentional:

- positive lag: the matching reference appears later in the recording;
- zero lag: the two input origins align;
- negative lag: the recording starts after part of the reference has already
  elapsed, or the recording leads the reference coordinate system.

An integer lag `l` represents `l / sampleRate` seconds. `DelayEstimate` retains
this integer `SampleCount` as the canonical value and exposes the interpolated
lag separately. Milliseconds are calculated only with the explicit sample
rate.

## Normalization and unequal lengths

The default `.overlapEnergy` normalized value is

```text
                  sum x[i] y[i + l]
rho[l] = ---------------------------------------
         sqrt(sum x[i]^2 * sum y[i + l]^2)
```

Every sum uses the same overlap at lag `l`; values therefore lie in `[-1, 1]`
apart from bounded Float rounding. This is energy/cosine normalization, not
Pearson correlation: means are not silently removed. Use the explicit audio
preprocessor when DC removal is desired.

Inputs may have different lengths. `minimumOverlapRatio` is multiplied by the
reference length and rounded upward, preventing one- or two-sample edge
overlaps from producing misleading normalized values of magnitude one. If the
recording cannot meet that requirement, analysis fails with
`insufficientOverlap`. A requested lag range is intersected with the range that
meets the overlap requirement; diagnostics record whether clamping occurred.
The `.full` sequence still represents every mathematical linear lag, while peak
searching only uses sufficiently overlapping lags.

## Direct and FFT implementations

The direct implementation computes each requested dot product with vDSP. It is
the reference implementation for short arrays and has worst-case time
complexity `O(MN)`. `.automatic` uses it only while the conservative estimate
`referenceCount * requestedLagCount` remains within `directOperationLimit`.

The production path converts correlation into convolution:

```text
rxy[l] = convolution(reverse(x), y)[l + M - 1]
```

Accelerate's single-precision complex transform is run at

```text
L = nextPowerOfTwo(M + N - 1)
```

Both inputs are zero-padded to `L`, their spectra are multiplied, and the
inverse transform is divided by `L`. Padding to at least `M + N - 1` is what
makes the result linear correlation. Omitting that padding would wrap the tail
onto the beginning and produce circular correlation, which is not suitable for
delay measurement.

FFT time complexity is `O(L log L)`. The reported conservative working-set
estimate includes eight `L`-element Float arrays (`32L` bytes), two Double
energy-prefix arrays, and returned/search sequences. For example, the tested
144,000 × 176,345 fixture uses `L = 524,288`, so FFT scratch is approximately
16 MiB before input, prefix, and result storage.

Each `CorrelationEngine` owns a bounded setup cache (four FFT lengths by
default). The cache is protected by a lock because Accelerate setup objects are
reference types; there is no mutable global state. Concurrent callers are safe,
and cache capacity can be set when constructing the engine. Direct loops check
cancellation at least every 2,048 lags. FFT analysis checks before and after
each Accelerate transform group; an individual vDSP transform cannot be
interrupted midway.

## Peak selection, interpolation, and confidence

Peak selection can score the absolute magnitude, positive values only, or
negative values only. The signed peak value is retained, so inverted polarity
is observable. The secondary peak is the strongest eligible value outside
`sidelobeExclusionRadius` around the primary peak. In this implementation,

```text
peakToSidelobeRatio = abs(primary) / abs(secondary)
```

The finite maximum `Double` value represents a nonzero peak with no measurable
secondary peak, keeping JSON valid.

Sub-sample refinement fits a parabola to selection scores at the integer peak
and its immediate neighbors:

```text
delta = 0.5 * (p[-1] - p[+1]) / (p[-1] - 2p[0] + p[+1])
fractionalLag = integerLag + delta
```

Interpolation is rejected if the peak is at a searched-sequence boundary, the
neighborhood is not a concave finite maximum, or the fitted offset leaves one
sample. `AnalysisDiagnostics.interpolationStatus` records the exact reason.
This is a local estimator, not a calibrated timebase. Its error depends on
bandwidth, SNR, peak symmetry and sample-rate conversion; it must not be
reported as better than the independent validation fixture supports. The
integer lag remains the auditable primary result. macOS result cards therefore
show the fractional value as an estimate rounded to three decimal samples;
machine-readable exports retain the full computed value and its interpolation
status.

Validity is separate from the selected lag. A result is `.valid` only if its
peak magnitude and peak-to-sidelobe ratio pass configured thresholds. A second
peak within `ambiguityTolerance` produces `.ambiguous`; other threshold
failures produce `.lowConfidence`. Silence and below-floor inputs fail with a
structured error instead of returning a random high-confidence lag. Thresholds
are tunable because periodic tones, sweeps, MLS, and real rooms have different
sidelobe behavior.

## APIs

```swift
let correlation = try await CorrelationEngine().correlate(
    reference: referenceSamples,
    observed: recordingSamples,
    configuration: CorrelationConfiguration(
        method: .automatic,
        searchRange: SampleLagRange(minimum: 0, maximum: 48_000),
        peakSelection: .absolute,
        sequenceOutput: .searchedRange
    )
)

let analysis = try await DelayAnalysisEngine().analyze(
    reference: referenceBuffer,
    observed: recordingBuffer,
    configuration: configuration
)
```

`DelayAnalysisEngine` rejects mismatched sample rates and channel counts. It
never resamples or downmixes implicitly. The channel is explicitly selected in
`CorrelationConfiguration`; callers can use `AudioPreprocessor` first when
conversion is required.

The developer CLI analyzes two imported files and emits Codable diagnostics:

```bash
swift run --package-path Packages/AudioLinkDSP AudioLinkCorrelationTool \
  reference.wav recording.wav --method fft --min-lag 0 --max-lag 96000 \
  --sequence searchedRange --json-output /tmp/correlation.json
```

## Verification

Swift tests cover exact lags `0, 1, 10, 100, 1000`, negative lag, partial
truncation, a 0.35-sample fractional fixture with deterministic white noise and
error below 0.08 sample,
gain/noise, inverted polarity, repeated signals, unrelated noise, silence,
NaN, invalid lag ranges, sample-rate/channel mismatches, 44.1/48/96 kHz,
cancellation, concurrent cache use, and direct/FFT sequence equivalence within
`2e-5`.

The debug performance fixture correlates a three-second, 144,000-frame
reference with a 176,345-frame recording. Its test ceiling is 10 seconds to
avoid claiming a portable hard real-time guarantee. It completed in about 0.39
seconds when run alone on the validation Apple Silicon host; this is evidence,
not a portable hard real-time API promise.

`Validation/Reference/reference_algorithms.py` is the independent equation-first
reference used by the DSP audit. `Validation/validate_correlation.py` is the
legacy validator and shares the project's overlap convention; it is useful for
regression but is not sufficient evidence by itself. The blind harness in
`Validation/BlindCases/run_blind_validation.py` generates 100 cases without
passing their truth parameters to Swift, then reads truth only after analysis.
If NumPy/SciPy are unavailable, validation is **unverified**, not a pass.

An earlier development run recorded:

```text
integer lag:              Swift 1234, SciPy 1234
fractional lag:           Swift 1233.999997105967
                          SciPy 1233.9999971075276
normalized peak:          Swift 0.999922454
                          SciPy 0.999922412
maximum sequence error:   6.57e-7
```

## Known limitations

- The method estimates one stationary delay, not sample-rate drift or a
  time-varying delay trajectory.
- FFT processing is in-memory rather than partitioned/streaming; multi-hour
  recordings need a coarse-to-fine or overlap-save search stage.
- There is no GCC-PHAT, whitening, band selection, room impulse response
  deconvolution, or multi-channel fusion yet.
- Parabolic interpolation is a local approximation and may be biased for broad
  asymmetric peaks, clipped waveforms, multipath, or sparse-band signals; the
  integer lag remains available unchanged. No universal fractional-sample
  accuracy claim is made.
- Confidence thresholds require calibration against real devices and acoustic
  environments before they should drive product-level pass/fail decisions.

The correlation engine's legacy `confidence` remains a lightweight peak-only
diagnostic. Product decisions should use the explainable multi-metric layer in
[MeasurementQuality.md](MeasurementQuality.md), which can return no public
delay for invalid or unmatched input.
