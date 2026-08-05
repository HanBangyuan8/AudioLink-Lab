"""Equation-first NumPy/SciPy references used by the DSP audit.

The Swift package is deliberately not imported here.  In particular, lag
indexing is constructed from the definition ``sum(x[i] * y[i + lag])`` and
fractional fixtures use a windowed-sinc interpolation rather than the signal
generator's implementation.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

import numpy as np
from scipy import signal


EPS = np.finfo(np.float64).tiny


def lag_axis(reference_size: int, observed_size: int) -> np.ndarray:
    """Return linear lags for r[l] = sum(x[i] y[i+l])."""
    if reference_size <= 0 or observed_size <= 0:
        return np.empty(0, dtype=np.int64)
    return np.arange(-(reference_size - 1), observed_size, dtype=np.int64)


def overlap_slices(reference_size: int, observed_size: int, lag: int) -> tuple[slice, slice]:
    start = max(0, -int(lag))
    end = min(reference_size, observed_size - int(lag))
    count = max(0, end - start)
    return slice(start, start + count), slice(start + int(lag), start + int(lag) + count)


def direct_correlation(reference: np.ndarray, observed: np.ndarray, normalize: bool = True) -> tuple[np.ndarray, np.ndarray]:
    """Direct, bounded-overlap correlation independent of scipy's lag API."""
    x = np.asarray(reference, dtype=np.float64).reshape(-1)
    y = np.asarray(observed, dtype=np.float64).reshape(-1)
    lags = lag_axis(x.size, y.size)
    result = np.zeros(lags.size, dtype=np.float64)
    for position, lag in enumerate(lags):
        xs, ys = overlap_slices(x.size, y.size, int(lag))
        xv, yv = x[xs], y[ys]
        numerator = float(np.dot(xv, yv))
        if normalize:
            denominator = float(np.sqrt(np.dot(xv, xv) * np.dot(yv, yv)))
            result[position] = np.clip(numerator / denominator, -1.0, 1.0) if denominator > EPS else 0.0
        else:
            result[position] = numerator
    return lags, result


def fft_correlation(reference: np.ndarray, observed: np.ndarray, normalize: bool = True) -> tuple[np.ndarray, np.ndarray]:
    """FFT linear correlation with explicit reverse/convolution mapping."""
    x = np.asarray(reference, dtype=np.float64).reshape(-1)
    y = np.asarray(observed, dtype=np.float64).reshape(-1)
    if x.size == 0 or y.size == 0:
        return np.empty(0, dtype=np.int64), np.empty(0, dtype=np.float64)
    # scipy's convolution is used only as a numerical FFT primitive; the lag
    # axis and normalization are independently defined above.
    numerator = signal.fftconvolve(x[::-1], y, mode="full")
    lags = lag_axis(x.size, y.size)
    if normalize:
        values = np.zeros_like(numerator, dtype=np.float64)
        for position, lag in enumerate(lags):
            xs, ys = overlap_slices(x.size, y.size, int(lag))
            denominator = float(np.sqrt(np.dot(x[xs], x[xs]) * np.dot(y[ys], y[ys])))
            values[position] = np.clip(numerator[position] / denominator, -1.0, 1.0) if denominator > EPS else 0.0
        return lags, values
    return lags, numerator.astype(np.float64, copy=False)


def parabolic_peak(values: Iterable[float], index: int) -> float | None:
    values = np.asarray(list(values), dtype=np.float64)
    if index <= 0 or index >= values.size - 1:
        return None
    left, center, right = np.abs(values[index - 1:index + 2])
    denominator = left - 2.0 * center + right
    if not np.isfinite(denominator) or denominator >= -np.finfo(float).eps:
        return None
    offset = 0.5 * (left - right) / denominator
    return float(offset) if np.isfinite(offset) and abs(offset) <= 1 else None


def windowed_sinc_delay(samples: np.ndarray, delay_samples: float, radius: int = 32) -> np.ndarray:
    """Apply a non-circular fractional delay using a Hann-windowed sinc.

    Positive delay moves energy later in the array.  The returned array has the
    same length and zero-filled boundaries, making the fixture truth explicit.
    """
    x = np.asarray(samples, dtype=np.float64).reshape(-1)
    output = np.zeros_like(x)
    for n in range(x.size):
        source = n - float(delay_samples)
        center = int(np.floor(source))
        offsets = np.arange(center - radius + 1, center + radius + 1)
        valid = (offsets >= 0) & (offsets < x.size)
        if not np.any(valid):
            continue
        distance = source - offsets[valid]
        window = 0.5 + 0.5 * np.cos(np.pi * distance / radius)
        output[n] = np.sum(x[offsets[valid]] * np.sinc(distance) * window)
    return output


def resample_reference(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    gcd = int(np.gcd(source_rate, target_rate))
    return signal.resample_poly(np.asarray(samples, dtype=np.float64), target_rate // gcd, source_rate // gcd)


@dataclass(frozen=True)
class DriftReference:
    slope: float
    intercept: float
    drift_ppm: float
    r_squared: float
    residuals: np.ndarray


def linear_drift(expected: np.ndarray, observed: np.ndarray) -> DriftReference:
    x = np.asarray(expected, dtype=np.float64)
    y = np.asarray(observed, dtype=np.float64)
    slope, intercept = np.polyfit(x, y, 1)
    fitted = slope * x + intercept
    residuals = y - fitted
    ss_res = float(np.dot(residuals, residuals))
    centered = y - float(np.mean(y))
    ss_total = float(np.dot(centered, centered))
    r2 = 1.0 if ss_total == 0 and ss_res == 0 else max(0.0, 1.0 - ss_res / ss_total) if ss_total else 0.0
    return DriftReference(float(slope), float(intercept), float((slope - 1.0) * 1e6), r2, residuals)


def mad_outliers(values: Iterable[float], threshold: float = 3.5) -> np.ndarray:
    values = np.asarray(list(values), dtype=np.float64)
    center = float(np.median(values))
    mad = float(np.median(np.abs(values - center)))
    if mad == 0:
        return np.flatnonzero(np.abs(values - center) > 0)
    modified_z = 0.6744897501960817 * np.abs(values - center) / mad
    return np.flatnonzero(modified_z > threshold)


def iqr_outliers(values: Iterable[float], multiplier: float = 1.5) -> np.ndarray:
    values = np.asarray(list(values), dtype=np.float64)
    q1, q3 = np.percentile(values, [25, 75], method="linear")
    return np.flatnonzero((values < q1 - multiplier * (q3 - q1)) | (values > q3 + multiplier * (q3 - q1)))


def deconvolve_impulse_response(sweep: np.ndarray, recording: np.ndarray, regularization: float = 1e-6) -> np.ndarray:
    """Regularized frequency-domain inverse (not a claim of standards compliance)."""
    x = np.asarray(sweep, dtype=np.float64).reshape(-1)
    y = np.asarray(recording, dtype=np.float64).reshape(-1)
    n = 1 << int(np.ceil(np.log2(max(1, x.size + y.size - 1))))
    X, Y = np.fft.rfft(x, n), np.fft.rfft(y, n)
    H = Y * np.conj(X) / (np.abs(X) ** 2 + float(regularization))
    return np.fft.irfft(H, n)[: y.size]


def schroeder_decay_metrics(ir: np.ndarray, sample_rate: float, peak_index: int | None = None) -> dict[str, float | None]:
    """Fit energy decay (not absolute sample amplitude) over requested ranges."""
    x = np.asarray(ir, dtype=np.float64).reshape(-1)
    if x.size == 0 or sample_rate <= 0:
        return {"edt": None, "rt20": None, "rt30": None, "rt60": None}
    peak = int(np.argmax(np.abs(x))) if peak_index is None else int(peak_index)
    if peak < 0 or peak >= x.size:
        return {"edt": None, "rt20": None, "rt30": None, "rt60": None}
    energy = x[peak:] ** 2
    reverse_integral = np.cumsum(energy[::-1])[::-1]
    if reverse_integral[0] <= 0:
        return {"edt": None, "rt20": None, "rt30": None, "rt60": None}
    db = 10.0 * np.log10(np.maximum(reverse_integral / reverse_integral[0], EPS))
    time = np.arange(db.size, dtype=np.float64) / sample_rate

    def fit(lower: float, upper: float) -> float | None:
        mask = (db <= lower) & (db >= upper) & np.isfinite(db)
        if int(np.count_nonzero(mask)) < 8:
            return None
        slope, _ = np.polyfit(time[mask], db[mask], 1)
        return float(60.0 / -slope) if np.isfinite(slope) and slope < 0 else None

    return {"edt": fit(0, -10), "rt20": fit(-5, -25), "rt30": fit(-5, -35), "rt60": fit(-5, -55)}


def windowed_dft(samples: np.ndarray, sample_rate: float, frequency: float) -> complex:
    x = np.asarray(samples, dtype=np.float64).reshape(-1)
    window = signal.windows.hann(x.size, sym=False) if x.size else x
    phase = np.exp(-2j * np.pi * frequency * np.arange(x.size) / sample_rate)
    coherent_gain = max(float(np.sum(window)), EPS)
    return complex(2.0 * np.sum(x * window * phase) / coherent_gain)


def frequency_response(input_samples: np.ndarray, output_samples: np.ndarray, sample_rate: float, frequencies: Iterable[float]) -> dict[str, np.ndarray]:
    frequencies = np.asarray(list(frequencies), dtype=np.float64)
    input_spectrum = np.asarray([windowed_dft(input_samples, sample_rate, f) for f in frequencies])
    output_spectrum = np.asarray([windowed_dft(output_samples, sample_rate, f) for f in frequencies])
    magnitude_db = 20.0 * np.log10(np.maximum(np.abs(output_spectrum) / np.maximum(np.abs(input_spectrum), EPS), EPS))
    phase = np.unwrap(np.angle(output_spectrum) - np.angle(input_spectrum))
    group_delay = np.zeros_like(phase)
    if frequencies.size > 1:
        group_delay[1:] = -np.diff(phase) / (2.0 * np.pi * np.diff(frequencies))
        group_delay[0] = group_delay[1]
    return {"magnitude_db": magnitude_db, "phase_radians": phase, "group_delay_seconds": group_delay}


def thd(samples: np.ndarray, sample_rate: float, fundamental_hz: float, harmonic_count: int = 5) -> dict[str, float | dict[int, float]]:
    fundamental = abs(windowed_dft(samples, sample_rate, fundamental_hz))
    if fundamental <= EPS:
        return {"ratio": 0.0, "harmonics": {}}
    harmonics: dict[int, float] = {}
    for harmonic in range(2, max(2, harmonic_count) + 1):
        harmonics[harmonic] = abs(windowed_dft(samples, sample_rate, fundamental_hz * harmonic)) / fundamental
    return {"ratio": float(np.sqrt(sum(value * value for value in harmonics.values()))), "harmonics": harmonics}

