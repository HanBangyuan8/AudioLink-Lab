# Adaptive Measurement Planner

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
