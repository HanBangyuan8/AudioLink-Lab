# Python signal validation

The formal generated corpus is driven by `generate_validation_dataset.py` and
`run_validation.py`; see the validation section of
[`Documentation/DeveloperAndValidation.md`](../Documentation/DeveloperAndValidation.md)
for the case matrix and tolerances.

```bash
python3 Validation/run_validation.py --profile quick
```

This directory contains an optional development-time reference validator. It
is not linked into AudioLink Lab and is not an application runtime dependency.

For the independent Prompt 27 review, use the equation-first implementation in
[`Reference/`](Reference/) and the blind 100-case harness in
[`BlindCases/`](BlindCases/). These commands require the same optional
NumPy/SciPy environment; missing dependencies are reported as **unverified**:

```bash
python3 Validation/Reference/run_reference.py reference.wav observed.wav --output /tmp/reference.json
python3 Validation/BlindCases/run_blind_validation.py
```

Create an isolated environment and install NumPy, SciPy, and Matplotlib:

```bash
python3 -m venv .venv-validation
source .venv-validation/bin/activate
python3 -m pip install -r Validation/requirements.txt
```

Generate the default 48 kHz, two-second, 20 Hz–20 kHz logarithmic sweep and
validate its frequency trajectory:

```bash
swift run --package-path Packages/AudioLinkDSP AudioLinkSignalTool \
  --output /tmp/audiolink-reference.wav
python3 Validation/validate_sweep.py /tmp/audiolink-reference.wav \
  --kind logarithmic --start-frequency 20 --end-frequency 20000 --duration 2 \
  --output /tmp/audiolink-reference.validation.png
```

The validator reads PCM or IEEE Float WAV, creates waveform and spectrogram
plots, estimates instantaneous frequency with a Hilbert transform, compares it
against the analytical sweep trajectory, and returns a non-zero exit status if
the configured median or 95th-percentile relative-error limits are exceeded.

Validate linear normalized correlation against SciPy using one deterministic
PCM16 fixture and the Swift command-line tool:

```bash
python3 Validation/validate_correlation.py \
  --generate-fixture /tmp/audiolink-correlation-validation \
  --run-swift \
  --plot /tmp/audiolink-correlation-validation/comparison.png
```

The validator uses the same lag convention and overlap-energy normalization as
AudioLinkDSP. It compares the integer lag, parabolic fractional lag, normalized
peak, and every value in the requested correlation sequence. NumPy, SciPy, and
Matplotlib remain development-only dependencies.
