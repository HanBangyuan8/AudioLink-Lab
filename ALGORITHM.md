# Algorithm and reproducibility guide

The DSP contract is documented in
[`Documentation/CorrelationAnalysis.md`](CorrelationAnalysis.md),
[`Documentation/TestSignals.md`](TestSignals.md),
[`Documentation/MeasurementQuality.md`](MeasurementQuality.md), and
[`Documentation/CalibrationAndStability.md`](CalibrationAndStability.md).

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
