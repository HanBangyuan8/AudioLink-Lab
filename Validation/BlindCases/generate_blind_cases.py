#!/usr/bin/env python3
"""Generate deterministic blind correlation cases.

The generator records truth separately from the audio. The Swift executable is
not given the delay, noise or polarity parameters; the harness reads truth only
after Swift has produced a result.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import wave

try:
    import numpy as np
except ModuleNotFoundError as error:  # pragma: no cover - environment guard
    raise SystemExit(
        "Blind validation is unverified: install Validation/requirements.txt "
        "(NumPy and SciPy) before generating cases."
    ) from error

from Validation.Reference.reference_algorithms import windowed_sinc_delay


def write_pcm16(path: Path, samples: np.ndarray, sample_rate: int) -> None:
    samples = np.clip(np.asarray(samples, dtype=np.float64), -1.0, 1.0)
    pcm = np.round(samples * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(int(sample_rate))
        handle.writeframes(pcm.tobytes())


def build_case(index: int, rng: np.random.Generator, root: Path) -> dict:
    sample_rate = int(rng.choice([44_100, 48_000, 96_000, 192_000]))
    fractional = index % 10 in (3, 7)
    negative = index % 9 == 0
    reference_size = int(rng.integers(1536, 3073))
    reference = rng.normal(0.0, 0.22, reference_size)
    reference += 0.08 * np.sin(2 * np.pi * 917 * np.arange(reference_size) / sample_rate)
    reference *= np.hanning(reference_size)
    delay = -int(rng.integers(1, 601)) if negative else int(rng.integers(0, 1201))
    if fractional:
        delay = int(delay)
        fraction = float(rng.choice([-0.75, -0.5, -0.25, 0.25, 0.5, 0.75]))
        true_delay = delay + fraction
    else:
        true_delay = float(delay)

    if delay >= 0:
        observed_size = reference_size + delay + int(rng.integers(256, 1025))
        observed = np.zeros(observed_size, dtype=np.float64)
        # The integer part is represented by the placement in the recording;
        # only the fractional part is interpolated inside the waveform.
        shifted = windowed_sinc_delay(reference, true_delay - delay) if fractional else reference
        end = min(observed_size, delay + shifted.size)
        observed[delay:end] = shifted[: end - delay]
        search_min, search_max = max(0, delay - 64), delay + 64
    else:
        start = min(reference_size - 1, -delay)
        observed_size = max(1024, reference_size - start)
        observed = reference[start:start + observed_size].copy()
        if fractional:
            observed = windowed_sinc_delay(observed, fraction)
        search_min, search_max = delay - 64, delay + 64

    gain = float(rng.uniform(0.35, 1.35))
    observed *= gain
    polarity = -1 if index % 13 == 0 else 1
    observed *= polarity
    noise_db = float(rng.choice([-np.inf, -40, -30, -20, -12]))
    if np.isfinite(noise_db):
        signal_rms = max(float(np.sqrt(np.mean(observed * observed))), 1e-12)
        observed += rng.normal(0.0, signal_rms * 10 ** (noise_db / 20), observed.size)
    if index % 17 == 0 and observed.size > delay + 100:
        echo = np.zeros_like(observed)
        echo[37:] = observed[:-37] * 0.35
        observed += echo
    clipped = index % 23 == 0
    if clipped:
        observed = np.clip(observed, -0.28, 0.28)
    name = f"case-{index:03d}"
    write_pcm16(root / f"{name}-reference.wav", reference, sample_rate)
    write_pcm16(root / f"{name}-observed.wav", observed, sample_rate)
    return {
        "name": name,
        "reference": f"{name}-reference.wav",
        "observed": f"{name}-observed.wav",
        "sample_rate": sample_rate,
        "expected_lag": true_delay,
        "integer_expected_lag": int(round(true_delay)),
        "minimum_lag": int(search_min),
        "maximum_lag": int(search_max),
        "fractional": fractional,
        "negative": negative,
        "polarity_inverted": polarity < 0,
        "clipped": clipped,
        "noise_db": noise_db,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=0xA710)  # deterministic, not an app seed
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(args.seed)
    cases = [build_case(index, rng, root) for index in range(100)]
    manifest = {"formatVersion": 1, "generator": "blind-cases-v1", "seed": args.seed, "cases": cases}
    (root / "truth.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    # This public manifest intentionally contains no exact floating-point truth.
    public = {"formatVersion": 1, "caseCount": len(cases), "cases": [{"name": case["name"], "sampleRate": case["sample_rate"]} for case in cases]}
    (root / "cases.json").write_text(json.dumps(public, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Generated {len(cases)} blind cases in {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
