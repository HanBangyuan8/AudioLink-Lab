# Independent DSP reference

`reference_algorithms.py` is an equation-first NumPy/SciPy implementation. It
does not import AudioLink packages and does not reuse Swift thresholds. It is a
development/validation dependency only:

```bash
python3 -m pip install -r Validation/requirements.txt
python3 -c 'from Validation.Reference.reference_algorithms import direct_correlation; print("reference import ok")'
```

The module exposes explicit intermediate values for lag axes, overlap-normalized
correlation, parabolic interpolation, fractional-delay fixture generation,
resampling, drift regression, robust outlier detection, regularized IR
deconvolution, Schroeder-style decay fits, windowed frequency response and THD.
The output must be treated as a numerical reference, not a standards
certification implementation.
