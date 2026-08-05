# AudioLink Lab measurement reference

This reference consolidates signal generation, import, correlation, quality, calibration, visualization, adaptive planning, and spatial measurement documentation.


---

<!-- Consolidated topic section. -->

## Algorithm and reproducibility guide

The DSP contract is documented in the correlation, signal, quality, and
calibration sections below.

The correlation convention is

```text
r[lag] = Σ reference[i] · observed[i + lag]
```

with linear (not circular) overlap, positive lag meaning the observed signal
arrives later, and milliseconds equal to samples / sample-rate × 1000. Direct
correlation is the short-input oracle; Accelerate FFT correlation is padded to
the next power of two and selected for larger inputs. Normalized values divide
by the RMS energy of the overlapping portions. Peak polarity, search range,
fractional parabolic interpolation, ambiguity, and quality thresholds are
stored in the result and versioned by `AudioLinkReleaseMetadata.algorithmVersion`.

Results are reproducible when the signal configuration and deterministic seed
are unchanged. Floating-point differences between CPU/OS versions are expected
within the validation tolerance; exact byte equality is required only for
seeded signal fixtures, not for every FFT implementation.


---

<!-- Consolidated topic section. -->

## Test signal system

`AudioLinkDSP` provides a single configuration-driven entry point for
deterministic reference signals:

```swift
let configuration = TestSignalConfiguration(
    kind: .logarithmicSweep,
    sampleRate: .hz48000,
    duration: try DurationSeconds(2),
    startFrequencyHertz: 20,
    endFrequencyHertz: 20_000,
    amplitude: 0.8
)
let generated = try TestSignalGenerator().generate(configuration: configuration)
try WAVExporter().write(generated.audio, to: destinationURL)
```

### PCM convention

`AudioSampleBuffer` is normalized Float32 PCM in non-interleaved planar order:
all frames of channel zero, then all frames of channel one. `frameCount` is the
per-channel count. The type exposes peak and RMS, safe gain and normalization,
raised-cosine fades, silence concatenation, mono/stereo conversion, direct
channel access, and copy-on-write storage. `WAVExporter` interleaves only while
encoding and defaults to broadly compatible little-endian PCM Int16.

### Sweep equations

For a linear sweep of active duration `T`, starting at `f0` and ending at `f1`:

```text
f(t) = f0 + (f1 - f0)t/T
φ(t) = 2π[f0 t + (f1 - f0)t²/(2T)]
x(t) = A sin(φ(t))
```

For a logarithmic sweep, with `r = f1/f0`:

```text
f(t) = f0 exp(ln(r)t/T)
φ(t) = 2π f0 T [exp(ln(r)t/T) - 1] / ln(r)
x(t) = A sin(φ(t))
```

Both expressions calculate absolute phase from time, so phase remains
continuous for ascending and descending sweeps. `shortChirp` uses the same
continuous linear-phase equation with a caller-selected short duration.

Fade gain is a raised cosine. For `N > 1` fade-in frames:

```text
g[n] = 0.5 - 0.5 cos(πn/(N-1)), 0 ≤ n < N
```

Fade-out uses the reversed curve. This gives exact zero and unity endpoints.

### Other signals

- Maximum Length Sequence uses a deterministic Galois LFSR and primitive
  feedback masks for orders 2 through 16. The configured sequence repeats if
  active duration exceeds `2^order - 1` frames.
- Band-limited noise starts with SplitMix64 pseudorandom samples, then uses a
  129-tap-or-shorter Hann-windowed sinc band-pass FIR and vDSP convolution. It
  is peak-normalized before fades.
- Impulse contains exactly one sample. It follows pre-roll silence and, when a
  fade-in is configured, is placed immediately after that fade region so the
  pulse is not erased.
- Silence contains normalized zero samples and still participates in the same
  duration, padding, channel, polarity, and export pipeline.

### Validation and limits

All frequency fields are finite, non-negative, and no greater than Nyquist;
amplitude is finite and in `0...1`; active duration contains at least one
rounded sample; fades cannot overlap; channel count is 1...32; and allocation
arithmetic is overflow-checked. Errors are returned as
`SignalGenerationError`, `AudioSampleBufferError`, or `WAVExportError`.

The current noise FIR is designed for repeatable reference and correlation
work, not mastering-grade brick-wall filtering. MLS orders above 16, RF64 WAV
files larger than 4 GiB, arbitrary multichannel downmix matrices, shaped noise,
and inverse-sweep/deconvolution filters are intentionally deferred.

See `Validation/README.md` for the optional Python waveform, spectrogram, and
frequency-trajectory verification workflow.


---

<!-- Consolidated topic section. -->

## Audio file import and preprocessing

AudioLinkDSP imports user-selected audio into the same canonical
`AudioSampleBuffer` used by the signal generator: normalized Float32,
non-interleaved planar PCM. File parsing and preprocessing do not import
SwiftUI and execute in cancellable detached tasks.

### Verified format matrix

The following combinations are generated during the test run and decoded back
through the production importer. This table describes verified behavior, not
every format that AVFoundation might theoretically open.

| Container | Encoding | Channels | Tested sample rate | Decoder |
| --- | --- | --- | --- | --- |
| WAV | signed PCM 16-bit | mono and stereo | 48 kHz mono, 44.1 kHz stereo | AudioLink native WAV |
| WAV | signed PCM 24-bit | mono and stereo | 48 kHz mono, 44.1 kHz stereo | AudioLink native WAV |
| WAV | signed PCM 32-bit | mono and stereo | 48 kHz mono, 44.1 kHz stereo, 96 kHz one-frame boundary | AudioLink native WAV |
| WAV | IEEE Float 32-bit | mono and stereo | 48 kHz mono, 44.1 kHz stereo | AudioLink native WAV |
| AIFF | signed PCM 16-bit | mono | 44.1 kHz | AVFoundation fallback |
| CAF | IEEE Float 32-bit | mono | 44.1 kHz | AVFoundation fallback |
| M4A | AAC | mono | 44.1 kHz | AVFoundation fallback |

WAV files are decoded in bounded chunks from interleaved little-endian file
data directly into planar Float PCM. The complete decoded Float buffer is kept
in memory because downstream correlation requires random access. AIFF, CAF, and
M4A use AVFoundation and are limited to the combinations above for the current
verified support claim.

### Import API

```swift
let imported = try await AudioFileImporter().importFile(
    at: selectedURL,
    progress: { progress in
        // This callback runs on a worker. Hop to MainActor before changing UI.
        Task { @MainActor in
            model.importProgress = progress.fractionCompleted
        }
    }
)
```

`AudioFileImporter` implements `AudioDecodingService`. It starts security-scoped
access only for the duration of an import and always stops it afterward. The
current milestone intentionally creates no persistent bookmark and retains no
long-term permission. A future SwiftUI `.fileImporter` should pass its selected
URL directly to this API.

`ImportedAudioFile` includes source URL/name, original on-disk format, canonical
internal format, sample rate, channel/frame counts, duration, peak, RMS,
clipping count, overall/per-channel DC offset, metadata, and preprocessing log.

### Explicit preprocessing

Every transformation is opt-in through `PreprocessingConfiguration`. Requested
operations run in this documented order:

1. select a zero-based channel;
2. downmix stereo to mono;
3. remove per-channel DC offset;
4. trim leading silence;
5. trim trailing silence;
6. apply a second-order Butterworth high-pass filter;
7. resample with `AVAudioConverter`;
8. invert polarity;
9. apply safe linear gain;
10. peak normalize or RMS normalize.

Channel selection and downmix are mutually exclusive. Peak and RMS
normalization are mutually exclusive. Safe gain and RMS normalization fail with
`operationWouldClip` rather than silently clipping. Silence trimming requires
an explicit amplitude threshold and optional minimum duration.

Each actual transformation appends a `PreprocessingLogEntry` containing its
sequence, parameters, and input/output frame counts. `wasResampled` is derived
from this log. Supplying no operations returns sample-identical audio and an
unchanged log.

Apple sample-rate conversion uses an output capacity equal to:

```text
round(inputFrameCount × destinationSampleRate / sourceSampleRate)
```

This excludes converter filter-tail frames from the analysis timeline. The
pipeline verifies that resulting duration differs by no more than one output
frame and records both frame counts and sample rates.

### Developer CLI

Inspect a file and print a sorted JSON report:

```bash
swift run --package-path Packages/AudioLinkDSP AudioLinkAudioFileTool input.wav
```

Apply explicit preprocessing and export PCM24 WAV plus a JSON report:

```bash
swift run --package-path Packages/AudioLinkDSP AudioLinkAudioFileTool input.wav \
  --downmix-mono --remove-dc --high-pass 20 --sample-rate 48000 \
  --peak-normalize 0.8 --encoding pcmInt24 \
  --output /tmp/processed.wav --json-output /tmp/processed.json
```

The CLI refuses to overwrite its input file.

### Current limits

- Native WAV support is little-endian RIFF only; RF64, Wave64, RIFX, packed
  non-byte-aligned PCM, and more than two channels are rejected.
- WAV LIST/INFO and BWF metadata are not parsed yet. Metadata currently records
  decoder and file-size context.
- The complete canonical Float buffer must fit in process memory. Import is
  asynchronous, chunked, cancellable, and reports progress, but is not a
  disk-backed streaming analysis implementation.
- AVFoundation fallback behavior can vary with OS codec availability. Only the
  exact AIFF, CAF, and M4A fixtures in the verified table are claimed.
- Resampling currently allocates complete input and output `AVAudioPCMBuffer`
  objects. Multi-hour recordings will need segmented SRC before that workload
  is considered production-supported.
- No security-scoped bookmarks or permanent external-file access are stored.


---

<!-- Consolidated topic section. -->

## Delay and correlation analysis

AudioLinkDSP estimates delay with linear cross-correlation. The implementation
is independent of SwiftUI and accepts either Float arrays through
`CorrelationEngine` or canonical `AudioSampleBuffer` values through
`DelayAnalysisEngine`.

### Definition and lag convention

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

### Normalization and unequal lengths

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

### Direct and FFT implementations

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

### Peak selection, interpolation, and confidence

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

### APIs

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

### Verification

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

### Known limitations

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
diagnostic. Product decisions should use the explainable multi-metric quality
layer in this reference, which can return no public delay for invalid or
unmatched input.


---

<!-- Consolidated topic section. -->

## Measurement quality assessment

Finding the largest correlation value is not sufficient evidence that a delay
is correct. `MeasurementQualityAnalyzer` combines correlation geometry, signal
condition, overlap, search placement, preprocessing history, and independent
channel results into an explainable `QualityAssessedMeasurement`.

The result deliberately contains both:

- a normalized `ConfidenceScore` with weighted components; and
- the original `QualityMetric` values, `QualityIssue` explanations, peak
  candidates, signal analysis, and delay diagnostics.

A score is never intended to replace those facts. For invalid/no-match input,
`QualityAssessedMeasurement.delay` is `nil`, even though a low correlation
maximum may remain available for engineering audit.

### Public flow

```swift
let assessed = try await MeasurementQualityAnalyzer().analyze(
    reference: importedReference,
    observed: importedRecording,
    correlationConfiguration: CorrelationConfiguration(
        method: .automatic,
        searchRange: SampleLagRange(minimum: 0, maximum: 96_000),
        peakSelection: .absolute
    ),
    thresholds: .standard
)

let content = MeasurementQualityFormatter().presentation(for: assessed.quality)
```

The analyzer explicitly requests the searched correlation sequence needed for
peak-shape analysis. It does not resample, downmix, remove DC, or normalize
audio. Sample-rate and channel-count mismatches remain structured errors. For
stereo input, each channel is correlated independently and the configured
channel remains the selected delay; the other channel is quality evidence.

`MeasurementQualityFormatter` returns Codable UI value types containing a
level, headline, summary, key metrics, warnings, and deduplicated recommended
actions. It does not import SwiftUI.

### Mathematically defined metrics

These definitions are algorithmic rather than empirical thresholds:

| Metric | Definition | Why it matters |
|---|---|---|
| Primary correlation | Absolute normalized coefficient at the selected lag | Measures waveform similarity independent of linear gain |
| Primary/secondary ratio | Primary magnitude divided by the strongest separated local peak | Measures whether another plausible delay competes with the default |
| Peak-to-sidelobe ratio | Primary magnitude divided by RMS correlation outside the primary guard radius | Measures peak prominence against the whole searched background |
| Peak width | Full width of absolute correlation at half maximum, with linear crossing interpolation | Broad peaks imply poorer timing resolution |
| Local sharpness | `(peak - mean(left, right)) / peak`, clamped to `0...1` | Measures immediate curvature around the integer maximum |
| Reference/recording RMS | `sqrt(mean(sample²))` on the selected channel | Very weak input is sensitive to quantization and environmental noise |
| SNR estimate | Least-squares scaled reference energy divided by aligned residual energy, in dB | Separates the modeled reference from noise and unmodeled audio |
| Clipping ratio | Full-scale recorded samples divided by all recorded samples | Clipping changes waveform shape and peak geometry |
| DC magnitude | Largest absolute per-channel sample mean | DC consumes headroom and biases energy normalization |
| Reference coverage | Overlap frames at the selected lag divided by reference frames | Low coverage indicates partial or truncated evidence |
| Boundary distance | Minimum distance from selected lag to either searched boundary | A boundary peak may mean the true maximum lies outside the search |
| Inverted polarity | Signed primary coefficient is negative | Inversion is real signal evidence, not absence of signal |
| Channel delay spread | Maximum minus minimum fractional channel delay | Large disagreement suggests routing or channel-specific processing |
| Channel peak spread | Maximum minus minimum absolute channel peak | Detects unequal channel match quality |

The least-squares SNR fits `observed ≈ gain × reference` over the selected
overlap. With fitted signal `s` and residual `e`:

```text
gain   = sum(x y) / sum(x²)
SNR dB = 10 log10(sum(s²) / sum(e²))
```

It is capped to `-120...120 dB` to keep Codable output finite. This is a model
fit estimate, not a calibrated acoustic SPL noise measurement.

The normalized correlation used by the engine is overlap-energy (cosine)
similarity, not Pearson correlation: it does not subtract a mean. A DC-removal
preprocessing step is therefore an explicit prerequisite when zero-mean
correlation is desired. Long silent overlap regions are excluded by the minimum
overlap policy and zero-energy windows return zero rather than a fabricated
coefficient.

### Local peaks and repeated-signal ambiguity

The analyzer scans absolute correlation for local maxima, then:

1. discards candidates below 20% of the primary magnitude;
2. sorts by magnitude with lower lag as the deterministic tie-break;
3. suppresses candidates within eight samples of an accepted candidate;
4. retains at most eight candidates;
5. marks candidates within 97% of the primary as ambiguous;
6. uses candidates within 90% for repeat-spacing analysis;
7. reports a periodic interval when at least three similar peaks have spacing
   agreement within the larger of two samples or 5%.

The original correlation-selected peak remains first and remains the default
delay candidate. Ambiguity lowers quality and exposes every retained candidate
for a future UI; it does not silently choose a different lag.

### Central empirical thresholds

All tunable values live in one Codable value,
`MeasurementQualityThresholds.standard`. No quality boundary is duplicated in
the evaluator or formatter. Custom policies are validated for finite values,
ordering, ranges, candidate capacity, score caps, and nonnegative weights before
audio analysis starts; invalid policy returns `MeasurementQualityError`.

| Metric | Poor/invalid boundary | Good boundary | Excellent/preferred boundary |
|---|---:|---:|---:|
| Selected-channel RMS | invalid `< 1e-7`; quiet `< 0.005` | — | `≥ 0.03` |
| Correlation magnitude | unusable `< 0.20` | `≥ 0.75` | `≥ 0.93` |
| Primary/secondary ratio | questionable `≤ 1.03` | `≥ 1.20` | `≥ 1.80` |
| Peak/sidelobe RMS ratio | questionable `≤ 2` | `≥ 5` | `≥ 12` |
| Fitted SNR | poor `< 6 dB` | `≥ 20 dB` | `≥ 35 dB` |
| Clipping ratio | severe `≥ 1%` | warning above `0.01%` | zero preferred |
| DC magnitude | severe `≥ 0.10` | warning above `0.02` | zero preferred |
| Reference coverage | severe `< 80%` | warning below `95%` | `100%` |
| Peak width | poor `≥ 32 samples` | `≤ 8 samples` | narrower is better |
| Local sharpness | zero is poor | `≥ 0.12` | `≥ 0.30` |
| Boundary distance | boundary is zero | warning `≤ 8 samples` | `≥ 64 samples` |
| Channel delay spread | severe `≥ 10 samples` | warning above `2 samples` | zero preferred |
| Channel peak spread | severe `≥ 0.30` | warning above `0.10` | zero preferred |

These thresholds are engineering starting points backed by deterministic
fixtures, not universal psychoacoustic laws. They need calibration against
real interfaces, Bluetooth paths, rooms, microphones, and reference-signal
families. Persisting the threshold value with future reports will make such
calibration auditable.

### Score composition and quality levels

Each metric is mapped piecewise-linearly to `0...1`. The weighted score is:

```text
raw confidence = sum(metricScore × weight) / sum(available weights)
```

Unavailable metrics, such as stereo agreement for mono input, are omitted and
the remaining weights are renormalized. The standard weights are:

| Component | Weight |
|---|---:|
| Primary correlation | 20% |
| Primary/secondary ratio | 12% |
| Peak/sidelobe ratio | 10% |
| Peak width | 5% |
| Local sharpness | 8% |
| Recording input level | 7% |
| Fitted SNR | 15% |
| Clipping | 8% |
| DC offset | 4% |
| Reference coverage | 5% |
| Search-boundary distance | 3% |
| Channel agreement | 3% |

Issue rules then cap the score instead of hiding serious defects inside an
average:

- fatal issue: `0`, level `invalid`, public delay removed;
- error: at most `0.49`, therefore `poor`;
- ambiguity, periodic peaks, boundary risk, partial reference, excessive
  noise, channel disagreement, clipping, or weak separation: at most `0.69`;
- other warnings: at most `0.84`, preventing `excellent`;
- informational preprocessing/polarity notes do not cap the score.

Level boundaries are:

```text
excellent     score >= 0.85
good          score >= 0.70
questionable  score >= 0.50
poor          score <  0.50 with usable signal
invalid       fatal issue or no usable reference match
```

`ConfidenceComponent.weightedContribution` values sum to the final capped
score, so a UI can explain both metric contributions and issue-driven caps.

### Quality issues

Every issue carries a stable code, severity, plain-language description,
technical detail including the measured boundary, and recommended action.
Implemented codes include:

- `inputTooQuiet`, `weakCorrelationPeak`, `excessiveNoise`;
- `clippingDetected`, `dcOffsetDetected`;
- `ambiguousPeak`, `lowPeakSeparation`, `periodicPeakPattern`;
- `peakAtSearchBoundary`, `searchRangeClamped`;
- `referencePartiallyMissing`, `possibleTruncation`;
- `polarityInverted`, `channelsDisagree`, `sampleRateConverted`;
- `broadCorrelationPeak`, `analysisUnavailable`.

Unrelated file URL, file name, or metadata is never used by any metric or score.
Explicit preprocessing history is used only for factual issues such as
`sampleRateConverted`.

### Verification and limits

Runtime-generated tests cover clean, low-level, noisy, clipped, DC-offset,
three-repeat periodic, boundary, inverted, truncated, silent, unrelated
non-silent, stereo-disagreement, resampled-log, metadata-invariance, Codable,
and formatter cases. They also assert deterministic score equality and that
confidence contributions sum to the final score.

Current limitations:

- Fitted SNR assumes a single linear gain and stationary aligned waveform; room
  response, filtering, or drift can appear as residual noise.
- FWHM and immediate curvature depend on test-signal bandwidth and should be
  compared with the same signal family.
- Channel agreement currently compares independently selected lags; it does
  not fuse channels into a new estimate.
- Candidate periodicity uses near-uniform spacing rather than a full harmonic
  model.
- Real-device threshold calibration and localization of user-facing strings
  remain future work.


---

<!-- Consolidated topic section. -->

## Calibration and long-term stability

### Calibration profiles

`CalibrationProfile` is immutable and identifies an exact route: input/output
device IDs, input/output channel mapping, sample rate, and buffer frame count.
It stores a fixed offset in samples plus the sample rate used to derive its
millisecond display, the measurement date, method, notes, and a 0…1 confidence.
`CalibrationProfile.matches(_:)` rejects any mismatch before an offset can be
applied. This prevents a profile measured for one aggregate device or buffer
size being used on another route.

`CalibrationApplicator.apply` returns `CalibratedDelayResult` containing both the
unchanged `rawDelay` and an optional derived delay:

```text
correctedSamples = rawSamples − knownFixedDelaySamples
correctedFractionalSamples = rawFractionalSamples − knownFixedDelaySamples
```

The sign is preserved for negative-lag measurements. A profile can be saved from
a manually entered known delay or from a measured physical loopback. Automatic
loopback capture is available through `PhysicalLoopbackCalibrator`, which invokes
the existing cancellable real-time runner and returns a profile from its captured
correlation result. The UI also supports recording a measured loopback offset
manually; it never pretends that a manual entry is a new capture.

SQLite schema version 4 stores profiles separately, adds `runs.calibration_json`, and stores anonymisation-controlled device snapshots.
Existing runs and raw delay rows are not rewritten during migration.

### Acoustic-path evidence

`AcousticPathDiagnosticsAnalyzer` inspects the canonical Float PCM and the searched
correlation sequence. It reports evidence, not facts:

- clipping ratio and input RMS;
- correlation-tail noise floor and an estimated SNR;
- local peak energy around the main response as a possible reverberation clue;
- separated secondary peaks as possible echoes, with candidates within 50 ms listed
  as possible early reflections;
- per-channel RMS spread, signed peak polarity, and recording/reference coverage.

Thresholds are centralized in `AcousticPathDiagnosticConfiguration`. Statements use
“possible” wording and include numeric evidence and a recommended next action.
They should not be interpreted as room impulse-response classification or acoustic
SPL measurements.

### Clock drift

For event observations `(expected_i, observed_i)` in samples, the estimator fits:

```text
observed_i = slope × expected_i + intercept + residual_i
drift_ppm = (slope − 1) × 1,000,000
```

`intercept` is the constant offset; it is intentionally reported separately from
drift. The fit includes R², RMS/max residual, confidence, and event indices marked
by a robust MAD residual rule. A comparison of early and late slopes produces a
possible-nonlinear-drift warning when their difference exceeds the configured ppm
threshold. At least three observations are required by default; missing events and
low-quality events lower confidence rather than producing a precise claim.

### Long-term test policy

`LongTermStabilityController` schedules short chirps at a fixed interval. It validates
the frozen route before every event and stops explicitly on a route change, sleep,
or interruption; it never silently mixes device conditions. Pause stops the active
runner, and resume revalidates the route. Each successful event retains its own
delay and quality, while failed events remain visible and are excluded from delay
statistics. A discontinuity is a jump between adjacent valid delays exceeding the
plan threshold. The report includes delay-over-time observations, jitter statistics,
failed markers, discontinuity indices, and an optional drift fit.

The current implementation is bounded by one short capture per event and by the
normal correlation memory limits. Multi-hour streaming and clock-domain resampling
are reserved for a later phase.


---

<!-- Consolidated topic section. -->

## Measurement visualization

AudioLink Lab's measurement review uses SwiftUI `Canvas`, Core Graphics, and
small immutable render models. It does not depend on a third-party chart
library, and the drawing layer never receives `ImportedAudioFile`, file URLs, or
the full measurement-quality object.

### Result organization

The completed measurement view is divided into five finite sections:

- **Summary**: canonical delay, integer/fractional samples, sample rate,
  correlation, polarity, quality, and important warnings.
- **Waveforms**: split reference and recording tracks, before/after alignment,
  sample/time cursor, delay marker, zoom, pan, and PNG export.
- **Correlation**: signed correlation, sample/millisecond lag axes, search
  boundaries, confidence thresholds, primary/secondary/candidate peaks,
  selection, and an explicit search-edge warning.
- **Diagnostics**: the explainable quality components, warnings, and recommended
  actions.
- **Processing Log**: only explicitly applied preprocessing operations and
  frame-count changes. Paths are deliberately excluded.

The peak-detail plot shows the integer samples around the selected peak, the
three-point parabolic interpolation curve, integer and fractional markers,
measured peak width, local noise-floor RMS, and confidence metrics.

### Render-model boundary

`VisualizationModels.swift` defines the platform-neutral values consumed by
the app:

- `WaveformRenderData` and `WaveformTrackRenderData`
- `CorrelationRenderData`
- `PeakDetailRenderData`
- `PlotViewport` and `PlotMarker`
- `DownsamplingStrategy`

These models are `Codable`, `Equatable`, and `Sendable`. Sample positions and
lags remain in sample units; explicit sample-rate conversion supplies seconds
and milliseconds. This keeps plotting independent from importing, analysis,
and SwiftUI.

### Downsampling algorithms

Waveform display uses a min/max envelope. For output bin `b` among `B` bins and
`N` visible samples, its exact source interval is:

```text
start(b) = floor(b N / B)
end(b)   = floor((b + 1) N / B)
```

Both the minimum and maximum sample in that half-open interval are retained.
This costs `O(N)` time and `O(B)` output memory and cannot hide a local impulse
or trough the way point sampling can.

Correlation display uses the same exact partition, but keeps three facts per
bin: signed minimum, signed maximum, and the value/lag with greatest absolute
magnitude. Positive peaks, negative/inverted peaks, and the strongest candidate
therefore survive decimation.

The display budget is quantized to powers of two and limited to 64...4096 bins,
normally about two bins per horizontal pixel. Only the currently visible
source range is scanned after zooming. A bounded actor-isolated cache retains
the 12 most recent waveform/correlation viewport and resolution combinations.
Superseded preparation is cancelled.

All sample scanning and peak-detail preparation runs in detached user-initiated
tasks. Only publication of completed immutable render models occurs on the main
actor. A 30-minute file therefore does not create millions of SwiftUI points or
nodes; a plotted track remains at most 4096 envelope bins.

### Coordinates and interaction

`PlotViewport` owns full-domain and visible-domain bounds. Zoom preserves its
normalized anchor, pan clamps at the domain edges, and the minimum visible span
prevents degenerate views. Waveforms expose seconds and sample position;
correlation exposes signed lag samples and milliseconds. Positive lag follows
the correlation convention documented in `CorrelationAnalysis.md`: the
recording occurs after the reference.

Before alignment, the recording remains in its original sample coordinate
space and the estimated-delay marker is drawn at the measured lag. After
alignment, the recording plot offset is the negative fractional delay and the
marker moves to the common zero origin. Samples are not resynthesized or
mutated for this display operation.

### PNG and clipboard export

`PlotPNGExporter` renders light or dark PNGs with Core Graphics/Core Text and
ImageIO. Exports include a title, units, axes, signed data, and relevant markers.
Dimensions are validated in the 64...8192 pixel range. Rendering and encoding
run away from the main actor before the result is written or copied to the
pasteboard. Render models contain display titles but never source URLs, so
private file paths cannot be embedded in the image.

### Tested behavior and limits

Tests verify extrema preservation, signed correlation peak preservation,
sample/time transforms, bounded zoom and pan, empty and single-sample safety,
analysis-to-marker consistency, fractional alignment, requested PNG dimensions,
absence of source paths in encoded PNG data, background preparation, and a
one-million-sample input constrained to the render-bin budget.

Known limits:

- Full-range preparation is still `O(N)` in the visible samples. It is
  memory-bounded and asynchronous, but the first view of a very long file may
  require noticeable scanning time; persistent multi-resolution overview files
  are reserved for the storage phase.
- The cache is in-memory and intentionally bounded; it is not retained between
  launches.
- Peak interpolation visualization uses the same three-point parabola as the
  delay estimate. It is explanatory, not a higher-order reconstruction of the
  underlying analog correlation surface.
- PNG export is raster-only in this phase. PDF/SVG and print layout are not
  implemented.
- Accessibility exposes plot identity, controls, candidate buttons, and numeric
  diagnostic content. A keyboard-addressable data table for every rendered bin
  is intentionally omitted because the render bins are implementation detail.


---

<!-- Consolidated topic section. -->

## Adaptive Measurement Planner

`AudioLinkAdaptive` is a deterministic rule engine, not a machine-learning
model. A `ProbeMeasurement` is optional; when present it updates the measured
environment before the same ordered rules are evaluated. Every changed field
has a `DecisionReason` with the rule, inputs, outcome, alternatives, and unknown
inputs.

Rules are evaluated in this order: low SNR (<12 dB) lengthens/repeats and uses
MLS; similar peaks use an aperiodic logarithmic sweep and a narrower range;
clipping lowers software amplitude (it never normalizes clipping away); weak
input (<0.01 RMS) raises software amplitude only within the explicit user cap;
a peak within 32 samples of a search boundary widens the range and post-roll;
and a long tail increases marker spacing and post-roll. Narrow-band paths do
not receive an automatic high-pass. Duration, amplitude, pre/post-roll and
retry counts are always clamped to `AdaptiveMeasurementLimits`.

Retries are finite and recorded as `RetryAttempt` values containing the reason,
changed parameters, expected improvement, and (after execution) actual
improvement. The controller stops after the
configured attempt count or when no improvement is observed. Locked parameters
and “automatic amplitude/retry” switches have precedence over environmental
heuristics. Unknown RMS/noise is surfaced in `unknownInputs`, not guessed.

Each plan also exposes a normalized, deterministic multi-objective score with
separate confidence, duration efficiency, loudness safety, ambiguity risk,
drift sensitivity, and environmental robustness components. The weighted total
uses 30/15/15/15/10/15 percent respectively; it is a planning trade-off, not a
probability of correctness and not a replacement for the later correlation
quality score.

This first slice chooses a signal and correlation policy; it does not itself
start an audio engine or perform the probe. It has no authority to change a
hardware gain or system route.


---

<!-- Consolidated topic section. -->

## Spatial Impulse Response Mapper

`AudioLinkSpatial` stores a room project, source/receiver positions, a raw
impulse response, processing log, and metric validity. Coordinates are 2D with
optional height and explicit metres/feet conversion. Sparse maps show measured
points; inverse-distance interpolation is enabled only with at least three
valid samples and is labelled as an estimate.

The IR extractor is a bounded, regularized matched-filter/deconvolution fallback
for development and fixture verification. It is not a claim of IEC/ISO
compliance. EDT/RT20/RT30/RT60 are Schroeder-inspired decay fits and are marked
invalid when the requested decay range is not present, the fit has insufficient
dynamic range, or a supplied noise floor reaches the fit range. C50, C80, D50 and centre
time use explicit energy windows. Direct level is dBFS, not calibrated SPL.

Octave and one-third-octave band energy are available as standard-inspired
analysis with explicit Nyquist/bin validity. They are not declared IEC/ISO
compliant filters. Calibrated microphone correction remains future work. A
missing or uncalibrated microphone must be stated in a report; no absolute
room-acoustic certification is produced. EDT/RT20/RT30/RT60 use a Schroeder-style
reverse cumulative **energy** decay and reject a range with fewer than eight
points or R² below 0.9. C50, C80, D50 and center time use energy after the
detected direct-sound peak; pre-peak samples are not silently folded into the
late-energy baseline. The sweep extractor remains a bounded, regularized
matched-filter fallback rather than a fully calibrated inverse-sweep
implementation.
