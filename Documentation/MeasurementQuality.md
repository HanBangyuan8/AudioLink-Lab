# Measurement quality assessment

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

## Public flow

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

## Mathematically defined metrics

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

## Local peaks and repeated-signal ambiguity

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

## Central empirical thresholds

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

## Score composition and quality levels

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

## Quality issues

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

## Verification and limits

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
