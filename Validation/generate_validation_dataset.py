#!/usr/bin/env python3
"""Generate the deterministic AudioLink DSP validation corpus.

The corpus is intentionally generated rather than checked in as binary data.
Every case is seeded, described in ``manifest.json``, and can be regenerated on
another machine with the same NumPy/SciPy versions.  The files are disposable
test artifacts, not application runtime dependencies.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

try:
    import numpy as np
except ModuleNotFoundError as error:
    raise SystemExit("Validation dependencies are missing. Install with: python3 -m pip install -r Validation/requirements.txt") from error
from scipy.io import wavfile


def write_wav(path: Path, sample_rate: int, samples: np.ndarray) -> None:
    samples = np.asarray(samples, dtype=np.float64)
    if samples.ndim == 1:
        channels = samples[:, None]
    else:
        channels = samples
    clipped = np.clip(channels, -1.0, 1.0)
    pcm = np.round(clipped * 32767.0).astype(np.int16)
    wavfile.write(path, sample_rate, pcm if samples.ndim == 2 else pcm[:, 0])


def delayed(reference: np.ndarray, lag: int, tail: int = 256, gain: float = 1.0) -> np.ndarray:
    return np.concatenate((np.zeros(lag), reference * gain, np.zeros(tail)))


def fractional_delay(reference: np.ndarray, lag: float, tail: int = 256) -> np.ndarray:
    integer = int(np.floor(lag))
    fraction = lag - integer
    source = np.concatenate((reference, [0.0]))
    shifted = (1.0 - fraction) * source[:-1] + fraction * source[1:]
    return np.concatenate((np.zeros(integer), shifted, np.zeros(tail)))


def pink_noise(size: int, rng: np.random.Generator) -> np.ndarray:
    white = rng.normal(0.0, 1.0, size)
    frequencies = np.fft.rfftfreq(size)
    spectrum = np.fft.rfft(white)
    spectrum[1:] /= np.sqrt(np.maximum(frequencies[1:], np.finfo(float).tiny))
    result = np.fft.irfft(spectrum, n=size)
    return result / max(np.max(np.abs(result)), np.finfo(float).tiny)


def base_reference(size: int, rng: np.random.Generator) -> np.ndarray:
    # Random phase plus two tones gives a sharp, non-periodic correlation peak.
    noise = rng.uniform(-0.65, 0.65, size)
    t = np.arange(size, dtype=np.float64) / 48_000.0
    return 0.75 * noise + 0.12 * np.sin(2 * np.pi * 1_071 * t) + 0.08 * np.sin(2 * np.pi * 7_313 * t)


def add_case(cases: list[dict], root: Path, name: str, sample_rate: int, reference: np.ndarray,
             observed: np.ndarray, category: str, expected_lag: int | None,
             expected: str, *, channel: int = 0, max_lag: int = 8_000) -> None:
    case_dir = root / name
    case_dir.mkdir(parents=True, exist_ok=True)
    ref_path = case_dir / "reference.wav"
    obs_path = case_dir / "observed.wav"
    write_wav(ref_path, sample_rate, reference)
    write_wav(obs_path, sample_rate, observed)
    cases.append({
        "name": name,
        "category": category,
        "sample_rate": sample_rate,
        "reference": str(ref_path.relative_to(root)),
        "observed": str(obs_path.relative_to(root)),
        "channel": channel,
        "min_lag": 0,
        "max_lag": max_lag,
        "expected_lag": expected_lag,
        "expected": expected,
    })


def build_dataset(root: Path, profile: str) -> dict:
    root.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(20260805)
    reference = base_reference(4_096, rng)
    cases: list[dict] = []

    add_case(cases, root, "integer-delay", 48_000, reference, delayed(reference, 1_234), "integerDelay", 1_234, "valid")
    add_case(cases, root, "fractional-delay", 48_000, reference, fractional_delay(reference, 37.5), "fractionalDelay", 38, "valid", max_lag=256)
    add_case(cases, root, "gain-change", 48_000, reference, delayed(reference, 321, gain=0.21), "gainChange", 321, "valid")
    add_case(cases, root, "polarity-inversion", 48_000, reference, delayed(reference, 777, gain=-0.8), "polarityInversion", 777, "valid")

    white = delayed(reference, 512, gain=0.8)
    white[512:512 + reference.size] += rng.normal(0.0, 0.08, reference.size)
    add_case(cases, root, "white-noise", 48_000, reference, white, "whiteNoise", 512, "valid")

    pink = delayed(reference, 640, gain=0.8)
    pink[640:640 + reference.size] += 0.06 * pink_noise(reference.size, rng)
    add_case(cases, root, "pink-noise", 48_000, reference, pink, "pinkNoise", 640, "valid")

    add_case(cases, root, "clipping", 48_000, reference, np.clip(delayed(reference, 123, gain=2.2), -0.25, 0.25), "clipping", 123, "qualityWarning")

    echo = delayed(reference, 256, tail=1_000, gain=0.9)
    echo_start = 256 + 700
    echo_length = max(0, reference.size - 700)
    echo[echo_start:echo_start + echo_length] += 0.42 * reference[:echo_length]
    add_case(cases, root, "reverberation", 48_000, reference, echo, "reverberation", 256, "qualityWarning")

    repeated = np.tile(reference[:512], 12)
    add_case(cases, root, "periodic-ambiguity", 48_000, reference[:512], delayed(repeated, 128, tail=0), "periodicAmbiguity", None, "ambiguous", max_lag=4_096)

    truncated = delayed(reference[:1_800], 900, tail=0)
    add_case(cases, root, "truncation", 48_000, reference, truncated, "truncation", 900, "qualityWarning")

    drift_source = delayed(reference, 1_000)
    drift_count = int(round(drift_source.size * (1.0 + 50e-6)))
    drifted = np.interp(np.linspace(0, drift_source.size - 1, drift_count), np.arange(drift_source.size), drift_source)
    add_case(cases, root, "sample-rate-drift", 48_000, reference, drifted, "sampleRateDrift", 1_000, "qualityWarning", max_lag=2_000)

    stereo = np.column_stack((delayed(reference, 432), delayed(reference, 432, gain=0.15)))
    add_case(cases, root, "stereo-mismatch", 48_000, reference, stereo, "stereoMismatch", 432, "qualityWarning", channel=0)

    silence = np.zeros(4_096, dtype=np.float64)
    add_case(cases, root, "long-silence", 48_000, silence, silence, "silence", None, "invalid", max_lag=2_000)

    high_reference = base_reference(8_192, rng)
    add_case(cases, root, "high-sample-rate", 96_000, high_reference, delayed(high_reference, 2_000), "highSampleRate", 2_000, "valid", max_lag=4_000)

    if profile == "full":
        long_reference = base_reference(48_000, rng)
        add_case(cases, root, "long-duration", 48_000, long_reference, delayed(long_reference, 4_800, tail=4_800), "longDuration", 4_800, "valid", max_lag=8_000)

    manifest = {"formatVersion": 1, "seed": 20260805, "profile": profile, "cases": cases}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("Validation/generated"))
    parser.add_argument("--profile", choices=("quick", "full"), default="quick")
    args = parser.parse_args()
    build_dataset(args.output, args.profile)
    print(f"Generated validation corpus at {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
