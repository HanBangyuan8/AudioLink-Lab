# Blind DSP cases

The cases are generated on demand; binary audio and truth data are intentionally
not committed. `generate_blind_cases.py` writes WAV files and a truth manifest
to a caller-provided temporary directory. The Swift correlation executable sees
only the WAV paths. `run_blind_validation.py` reads the truth manifest only
after each Swift invocation has completed.

The deterministic corpus contains 100 cases spanning positive/negative and
fractional delays, gain, polarity, white noise, clipping, echoes, truncation,
periodic ambiguity, high sample rate and long silence. It is a detection
regression suite, not a claim that every acoustic path is identifiable.

```bash
python3 Validation/BlindCases/run_blind_validation.py
```

NumPy/SciPy are development-only dependencies. If they are unavailable the
script fails explicitly and the validation is reported as unverified.
