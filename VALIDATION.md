# Validation corpus

`Validation/generate_validation_dataset.py` creates a deterministic, disposable
corpus with integer and fractional delays, gain, polarity, white/pink noise,
clipping, echoes/reverberation, truncation, sample-rate drift, periodic
ambiguity, stereo mismatch, silence, 96 kHz, and a full-profile long input.

`Validation/run_validation.py` runs each pair through the release-built
`AudioLinkCorrelationTool`, calculates the same linear normalized correlation
with NumPy/SciPy, checks integer lag/peak agreement, and expects invalid or
ambiguous outcomes where appropriate. It writes `validation-summary.json` and
`validation-summary.md` and exits non-zero for a mismatch.

The Python environment is optional and never used by the app:

```bash
python3 -m pip install -r Validation/requirements.txt
python3 Validation/run_validation.py --profile quick
python3 Validation/run_validation.py --profile full --output Validation/results/full
```

Tolerance is intentionally explicit: one sample for cross-implementation peak
location, 5e-3 for normalized peak, and a small additional allowance for the
fractional-delay fixture. Acoustic quality labels are expected categories, not
ground truth about a physical room.

The v1.1 alpha package tests additionally cover deterministic planner rule
selection, synthetic IR extraction/metric validity, sparse-map warnings, and
multi-node readiness/stale-session rejection. No real room, hardware matrix,
DAW, or more-than-two-device result is represented by these automated tests.

## Independent DSP review

`Validation/Reference/reference_algorithms.py` re-implements the equations
without importing Swift code. `Validation/BlindCases` generates 100 deterministic
WAV-only cases and reveals the exact truth manifest only after Swift analysis.
This is the preferred numerical audit path. It requires NumPy and SciPy from
`Validation/requirements.txt`; a missing environment is an explicit
**unverified** result, never a successful validation.
