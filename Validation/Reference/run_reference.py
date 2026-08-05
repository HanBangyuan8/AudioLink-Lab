#!/usr/bin/env python3
"""Emit machine-readable independent reference intermediates for two WAVs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

try:
    import numpy as np
    from scipy import __version__ as scipy_version
    from scipy.io import wavfile
except ModuleNotFoundError as error:  # pragma: no cover - environment guard
    raise SystemExit(
        "DSP reference validation is unverified: install Validation/requirements.txt "
        "(NumPy and SciPy) before running this command."
    ) from error

from reference_algorithms import direct_correlation, fft_correlation, parabolic_peak


def read_mono(path: Path) -> tuple[int, np.ndarray]:
    rate, data = wavfile.read(path)
    data = np.asarray(data)
    if data.ndim == 2:
        data = data[:, 0]
    if np.issubdtype(data.dtype, np.integer):
        scale = max(abs(np.iinfo(data.dtype).min), np.iinfo(data.dtype).max)
        data = data.astype(np.float64) / float(scale)
    else:
        data = data.astype(np.float64)
    return int(rate), data


def json_float(value: float | None) -> float | None:
    return None if value is None or not np.isfinite(value) else float(value)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("observed", type=Path)
    parser.add_argument("--minimum-lag", type=int)
    parser.add_argument("--maximum-lag", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    reference_rate, reference = read_mono(args.reference)
    observed_rate, observed = read_mono(args.observed)
    lags, direct = direct_correlation(reference, observed)
    _, fft = fft_correlation(reference, observed)
    selected = np.ones(lags.size, dtype=bool)
    if args.minimum_lag is not None:
        selected &= lags >= args.minimum_lag
    if args.maximum_lag is not None:
        selected &= lags <= args.maximum_lag
    selected_indices = np.flatnonzero(selected)
    peak_index = int(selected_indices[np.argmax(np.abs(direct[selected]))]) if selected_indices.size else None
    report = {
        "reference": str(args.reference.name),
        "observed": str(args.observed.name),
        "sampleRateHertz": {"reference": reference_rate, "observed": observed_rate},
        "dependencies": {"numpy": np.__version__, "scipy": scipy_version},
        "lagConvention": "r[lag] = sum(reference[i] * observed[i + lag])",
        "lags": {"first": int(lags[0]) if lags.size else None, "last": int(lags[-1]) if lags.size else None},
        "selectedPeak": {
            "lag": int(lags[peak_index]) if peak_index is not None else None,
            "value": json_float(direct[peak_index]) if peak_index is not None else None,
            "fractionalOffset": json_float(parabolic_peak(direct[selected], int(np.argmax(np.abs(direct[selected]))))) if peak_index is not None else None,
        },
        "maxDirectFFTAbsoluteError": float(np.max(np.abs(direct - fft))) if direct.size else 0.0,
        "directCorrelation": {"lags": lags.tolist(), "values": direct.tolist()},
        "fftCorrelation": {"lags": lags.tolist(), "values": fft.tolist()},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
