# AudioLink Lab DSP and measurement validation review

Date: 2026-08-05  
Review scope: Prompt 27, independent numerical review of the Swift signal,
correlation, quality, statistics, drift, spatial and plugin paths.

This review treats existing tests and documentation as claims to verify. A
passing unit test is not treated as an independent proof when its fixture is
constructed from the implementation under test.

## 1. Actual algorithm inventory

| Area | Implementation | Formula/units actually used | Boundary and assumptions | User-visible | Independent status |
|---|---|---|---|---|---|
| Log sweep | `AudioLinkDSP/SignalGenerator.swift` | `phase = 2π f0 T (exp(log(f1/f0)t/T)-1)/log(f1/f0)`; samples are normalized Float | Positive frequencies, `t < T`, Nyquist checked | Signal and reports | Equation reviewed; sweep script requires SciPy and is unverified in this environment |
| Linear sweep/chirp | `SignalGenerator.swift` | `phase=2π(f0t+½kt²)` | Frequencies must be ordered and below Nyquist | Signal | Unit tests only; independent trajectory unverified |
| MLS | `SignalGenerator.swift` | XOR LFSR masks, ±amplitude | Order 2…16, nonzero seed; sequence period is not checked at runtime | Signal | Determinism tested; maximal-period property not independently verified for every mask |
| Pseudo-random noise | `SignalGenerator.swift` | SplitMix64 white noise, windowed ideal band-pass FIR, peak-scaled | FIR is a finite development filter, peak scaling changes RMS | Signal | Determinism tested; spectral tolerance unverified |
| Fades | `SignalGenerator.swift`, `AudioSampleBuffer.swift` | Raised cosine `0.5±0.5 cos(πn/(N-1))` | One-frame fade is zero; fade lengths may not overlap | Signal | Covered by Swift tests |
| WAV conversion | `AudioFileImporter.swift` | AVFoundation decode to planar Float32 | Tested WAV PCM/IEEE variants; other formats are capability-dependent | Import UI/CLI | Fixture tests, no independent decoder comparison |
| Resampling | `AudioPreprocessor.swift` | `AVAudioConverter`, expected frames `round(N·rateOut/rateIn)` | Duration error bounded to one output frame; converter filter phase is not independently characterized | Delay analysis | Swift duration tests; SciPy comparison unverified |
| DC removal | `AudioPreprocessor.swift` | Per-channel `x - mean(x)` | Mean is over the complete selected file | Processing log/quality | Covered by tests |
| High-pass | `AudioPreprocessor.swift` | 2nd-order Butterworth-style biquad, direct-form recurrence | Single forward pass, startup state zero; no formal filter conformance claim | Processing log | Numerical stability reviewed; frequency response unverified |
| Correlation | `CorrelationAnalyzer.swift` | `r[l]=Σ x[i]y[i+l]`, linear overlap; FFT `conv(reverse(x),y)` with `L=nextPow2(M+N-1)` | Positive lag means recording is later; minimum overlap prevents edge peaks | Delay and plots | Direct/FFT Swift tests; independent reference added but dependencies unavailable |
| FFT/inverse FFT scaling | `CorrelationAnalyzer.swift` / `FFTSetupCache` | Complex forward transforms, pointwise product, inverse transform, then `1/L` scaling | Zero-padded linear convolution; setup cache is bounded and locked | Indirectly delay/plots | Direct-versus-FFT sequence regression; independent numeric comparison unverified |
| Normalization | `CorrelationAnalyzer.swift` | `r/sqrt(Σx²Σy²)` over the same overlap | Cosine similarity, not mean-subtracted Pearson; zero energy → 0 | Delay/quality | Semantics corrected in docs; independent run unverified |
| Peak selection | `CorrelationAnalyzer.swift` | absolute/positive/negative score; secondary excludes guard radius | Ties are deterministic by first index; one secondary is not a noise distribution | Delay/quality | Covered by Swift tests |
| Fractional peak | `CorrelationAnalyzer.swift` | Three-point parabolic offset `½(p-−p+)/(p−−2p0+p+)` | Disabled at boundary/degenerate curvature; local approximation only | Delay/plots/reports | Existing 0.35 fixture only; broad blind precision unverified; UI rounded to 0.001 sample |
| Peak-to-sidelobe | correlation + `MeasurementQualityAnalyzer.swift` | Legacy ratio uses primary/one secondary; quality layer uses primary/RMS outside guard | RMS background can be inflated by unrelated structure; thresholds empirical | Quality | Formula reviewed; no calibration dataset |
| SNR | `MeasurementQualityAnalyzer.swift` | Least-squares `gain=Σxy/Σx²`; `10log10(Σs²/Σe²)` | Model-fit SNR, not acoustic SPL; capped ±120 dB | Quality | Formula reviewed; no independent noise calibration |
| Clipping/DC | `AudioMetricsAnalyzer.swift`, quality analyzer | Full-scale sample ratio; per-channel means | Float threshold near 1.0; file-wide ratio | Quality/import | Unit tests and code review |
| Ambiguity | quality analyzer | Local maxima ≥20% primary, 8-sample separation, 97% equal-peak warning, 5% spacing tolerance | Heuristic; periodicity is not proof of physical echo | Quality/diagnostics | Synthetic tests; empirical thresholds uncalibrated |
| Percentiles | `StatisticalAnalyzer.swift` | Hyndman–Fan type 7 | Small samples are labeled insufficient/preliminary | History/reports | Matches NumPy/R definition by formula; SciPy run unverified |
| Jitter | `StatisticalAnalyzer.swift` | Sample SD, peak-to-peak, MAD, IQR are separate fields | Failed and warm-up runs excluded from delay population; original runs retained | Statistics | Swift known-dataset tests |
| Outliers | `StatisticalAnalyzer.swift` | scaled MAD (`MAD×1.4826`) or IQR fences | Marked, optionally excluded; MAD=0 flags any non-identical value | Statistics | Swift tests; independent reference added |
| Drift | `ClockDriftEstimator.swift` | fit `observed = slope·expected + intercept`; `ppm=(slope−1)×10⁶` | Ordinary least squares, optional one-pass residual rejection; ≥3 points | Drift report/UI | Synthetic ±10…100 ppm tests; robust/nonlinear limits remain estimates |
| Calibration | `CalibrationModels.swift` | corrected delay is raw delay minus known fixed offset when applied | Profile route/rate matching required; raw result retained | Result/report | Route matching tests; sign reviewed |
| IR extraction | `ImpulseResponseAnalyzer.swift` | bounded matched filter `Σ recording[k+i]·sweep[i]/(Σsweep²+λ)` | Not a true inverse-sweep/harmonic-separated deconvolution; causal nonnegative lag only | Spatial | Delayed impulse test; production IR accuracy unverified |
| EDT/RT20/30/60 | `ImpulseResponseAnalyzer.swift` | **After fix:** reverse cumulative energy, dB fit, `RT60=60/−slope` | Requires ≥8 points and R²≥0.9 in requested range; standard compliance not claimed | Spatial/report | New synthetic exponential regression; real room validation unverified |
| C50/C80/D50/center | `ImpulseResponseAnalyzer.swift` | Energy after direct peak; early windows 50/80 ms; centroid `ΣtE/ΣE` | No pre-peak energy in late denominator after fix | Spatial/report | Formula reviewed; band-specific validation unverified |
| Frequency bands | `FrequencyBandAnalyzer.swift` | Brute-force DFT-bin energy inside octave/third-octave bounds | Not an IEC/ISO filter bank; short signals may contain no bins | Spatial/report | Unit test only; standards conformance not claimed |
| Plugin response | `PluginAnalysisMath.swift` | DFT magnitude; Hann weighting after fix; phase difference with unwrap; finite-difference group delay | Phase unwrap requires sufficiently dense/ordered frequency samples | Plugin reports | Fixed branch-wrap defect; mock test added; third-party AU unverified |
| Plugin THD | `PluginAnalysisMath.swift` | Windowed DFT harmonic RMS/fundamental | Leakage and Nyquist aliasing still limit interpretation | Plugin reports | Mock types exist; no external plugin validation |
| Plugin tail | `PluginAnalysisMath.swift` | Last sample above threshold / sample rate | Threshold-dependent, not energy decay or perceptual tail | Plugin reports | Mock test only |
| Distributed uncertainty | `AudioLinkDistributed/ClockSynchronization.swift` | median offset/RTT, MAD-like spread, root-sum-square budget | Network offset is not acoustic arrival; asymmetry and age are heuristics | Distributed reports | Simulated tests only |

## 2. Lag and time semantics

The single documented convention is:

```text
r[lag] = Σ reference[i] · recording[i + lag]
```

The full linear lag range is `-(M−1)…(N−1)`. A positive lag means the matching
recording content occurs later than the reference origin. Fractional lag has the
same sign. Trimming changes the coordinate origin and must be logged; resampling
changes the sample unit and must be explicit. Calibration is a derived result:
`corrected = raw − knownFixedDelay` when the profile is applied. Network RTT and
clock offset are never substituted for acoustic correlation.

The FFT index mapping was independently derived as
`conv(reverse(reference), recording)[lag + M − 1]`; zero padding to at least
`M+N−1` makes it linear rather than circular. Direct and FFT code agree in the
existing Swift suite. The independent NumPy/SciPy comparison is present but
cannot be executed on this host because NumPy is not installed.

## 3. Independent reference and blind validation

Added:

- `Validation/Reference/reference_algorithms.py`: explicit direct and FFT
  correlation, overlap normalization, parabolic interpolation, windowed-sinc
  fractional delay, `resample_poly`, drift fit, MAD/IQR, regularized frequency
  deconvolution, Schroeder energy decay, windowed frequency/phase/group delay,
  and THD.
- `Validation/Reference/run_reference.py`: machine-readable intermediate JSON
  with NumPy/SciPy versions and the complete correlation sequences.
- `Validation/BlindCases/generate_blind_cases.py`: deterministic 100-case corpus
  with truth held separately from WAV inputs.
- `Validation/BlindCases/run_blind_validation.py`: invokes Swift first and
  reveals truth only after each result is written.

Current status: Python reference/100-case blind run is **unverified** in this
environment (`python3` has neither NumPy nor SciPy). It is not reported as a
pass. Swift package regression tests for the changed spatial and plugin paths
pass; the full package and app matrix is reported separately in the final handoff.

## 4. Findings and risk classification

### Critical

None remain after this review. No evidence was found that the primary linear
correlation lag sign or FFT padding is wrong.

### High

1. **Spatial decay metrics used sample-amplitude fits** —
   `ImpulseResponseAnalyzer.decayFit`. This could report plausible RT values for
   data that does not satisfy the energy-decay model. **Fixed:** reverse
   cumulative energy, dynamic-range/sample-count checks, R² validity, explicit
   noise-floor rejection and confidence are now used. Algorithm version changed.
2. **C50/C80/D50 included pre-direct energy** — same file. This biased ratios for
   recordings with leading noise or offset. **Fixed:** all energy metrics start at
   the detected direct peak and C50/C80 explanations state that fact.
3. **Acoustic “coverage” used file-length ratio** —
   `AcousticPathDiagnosticsAnalyzer`. A long recording could look complete even
   when the selected correlation overlap was truncated. **Fixed:** use the
   primary peak overlap count divided by reference frames.
4. **Plugin group delay could jump at phase branch cuts** —
   `PluginAnalysisMath.phaseResponse`. **Fixed:** unwrap response phase before
   differentiation and add a dense-frequency fixed-delay regression. Sparse
   frequency grids remain inherently ambiguous and are documented.
5. **Fractional lag was displayed with unsupported precision** — result cards
   showed four or six decimal places despite a local parabolic estimator and no
   calibration. **Fixed:** visible macOS fractional values now say “estimate” and
   use three decimal samples; machine-readable exports retain raw values.

### Before/after evidence

- The old sparse wrapped-phase plugin fixture showed a maximum absolute group-
  delay error of about `4.0816e-4 s` for a fixed-delay case. After unwrapping
  and using a dense frequency grid, the regression is below `1e-8 s`. This is
  not a claim that sparse grids are recoverable; their phase branch spacing is
  intrinsically ambiguous.
- The spatial decay change has a passing synthetic Swift regression for a known
  exponential, but no independent Python numeric comparison was possible on
  this host because NumPy/SciPy are unavailable. The high-noise regression also
  confirms that RT metrics become invalid when the supplied noise floor reaches
  the requested fit range. The improvement is therefore a validated
  implementation change, not a measured cross-language error reduction.
- Integer direct/FFT correlation continues to pass the Swift equation and
  sequence tests. Independent reference error and the 100-case detection rate
  remain unverified until the optional Python dependencies are installed.

### Medium

- Confidence is a deterministic weighted policy, not a calibrated probability;
  thresholds and caps remain empirical. The UI must show component metrics and
  limitations, not just the scalar.
- Normalized correlation is cosine similarity, not Pearson correlation. This is
  now explicit in docs; callers needing zero-mean behavior must request DC
  removal.
- `peakToSidelobeRatio` in the core correlation result is primary/one-secondary,
  while the quality layer also computes primary/RMS-background. Both are kept
  but must not be conflated in reports.
- The IR extractor is a matched-filter fallback despite the deconvolution name;
  harmonic-separated inverse sweeps are not yet available.
- Octave/third-octave analysis is DFT-bin energy, not a verified standards
  filter-bank implementation.
- Drift confidence is an R²/sample-count heuristic and does not model weighted
  observation uncertainty, clock resets or route changes automatically.
- Plugin latency uses first non-zero output and is therefore a probe estimate,
  not a general processing-latency proof for noisy/dynamic plugins.

### Low

- Signal and high-pass spectral responses have no committed independent plots in
  the current host because SciPy is unavailable.
- `AudioMetricsAnalyzer` exposes all-channel RMS for file summaries while the
  quality analyzer computes selected-channel RMS; labels are explicit but users
  should not compare the two fields without checking channel scope.

## 5. Versioning and historical results

`AudioLinkReleaseMetadata.algorithmVersion` is now
`correlation-v2-dsp-audit`; spatial metadata is `spatial-ir-schroeder-v2`.
Existing SQLite/report/bundle records keep their original algorithm strings and
are not silently reinterpreted. Re-analysis is required to obtain corrected
spatial metrics. The database, report and protocol schema versions were not
changed by this review.

## 6. What can reasonably be claimed

**Trustworthy within stated assumptions:** integer linear-correlation lag for
finite, finite-valued, same-rate inputs with sufficient overlap; direct/FFT
agreement within the existing numerical tolerance; deterministic seeded signal
generation; sample-count/duration conversion; type-7 percentiles and explicitly
named run statistics; calibration arithmetic when a matching profile is used.

**Useful estimates:** parabolic fractional lag, quality level/score, SNR,
ambiguity and echo clues, drift ppm, acoustic coverage, plugin measured latency,
windowed frequency/phase/THD, Schroeder-inspired spatial metrics on sufficiently
long clean IRs.

**Not validated here:** universal fractional-sample accuracy, real-room RT
accuracy, IEC/ISO filter compliance, true inverse-sweep harmonic separation,
third-party AU behavior, multi-hour drift, Bluetooth/network acoustic timing,
multi-node synchronization precision, and any absolute SPL claim.

## 7. Recommended next validation

Install the pinned NumPy/SciPy environment from `Validation/requirements.txt`,
run the 100 blind cases and reference intermediate comparison, then run real
hardware fixtures at 44.1/48/96/192 kHz. Add recorded room IRs with known
exponential decays and at least one third-party AU tested in the isolated helper.
Do not raise displayed fractional precision or promote quality scores to
probabilities without those results.
