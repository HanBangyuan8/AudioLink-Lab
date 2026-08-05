# Calibration and long-term stability

## Calibration profiles

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

## Acoustic-path evidence

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

## Clock drift

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

## Long-term test policy

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
