#!/usr/bin/env python3
"""Generate or read a fixture and compare SciPy correlation with Swift JSON."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

os.environ.setdefault(
    "MPLCONFIGDIR", str(Path(tempfile.gettempdir()) / "audiolink-matplotlib-cache")
)

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy import signal
from scipy.io import wavfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate AudioLinkDSP normalized linear cross-correlation against SciPy."
    )
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--observed", type=Path)
    parser.add_argument("--swift-json", type=Path)
    parser.add_argument(
        "--generate-fixture",
        type=Path,
        help="Generate deterministic PCM16 WAVs in this directory before validating.",
    )
    parser.add_argument(
        "--run-swift",
        action="store_true",
        help="Run AudioLinkCorrelationTool and create --swift-json automatically.",
    )
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--min-lag", type=int, default=0)
    parser.add_argument("--max-lag", type=int, default=2_000)
    parser.add_argument("--plot", type=Path)
    parser.add_argument("--peak-tolerance", type=float, default=5e-4)
    parser.add_argument("--fractional-lag-tolerance", type=float, default=0.05)
    return parser.parse_args()


def write_fixture(directory: Path) -> tuple[Path, Path, int]:
    directory.mkdir(parents=True, exist_ok=True)
    sample_rate = 48_000
    delay = 1_234
    rng = np.random.default_rng(20_260_804)
    reference = rng.uniform(-0.75, 0.75, 4_096)
    observed = np.concatenate(
        [
            np.zeros(delay),
            reference * 0.37 + rng.normal(0, 0.002, reference.size),
            np.zeros(512),
        ]
    )
    reference_path = directory / "correlation-reference.wav"
    observed_path = directory / "correlation-observed.wav"
    wavfile.write(reference_path, sample_rate, np.round(reference * 32767).astype(np.int16))
    wavfile.write(observed_path, sample_rate, np.round(observed * 32767).astype(np.int16))
    return reference_path, observed_path, delay


def normalized_mono(path: Path) -> tuple[int, np.ndarray]:
    sample_rate, samples = wavfile.read(path)
    if samples.ndim == 2:
        samples = samples[:, 0]
    if np.issubdtype(samples.dtype, np.integer):
        scale = max(abs(np.iinfo(samples.dtype).min), np.iinfo(samples.dtype).max)
        samples = samples.astype(np.float64) / float(scale)
    else:
        samples = samples.astype(np.float64)
    if not np.all(np.isfinite(samples)):
        raise ValueError(f"{path} contains NaN or infinity")
    return int(sample_rate), samples


def overlap(reference_size: int, observed_size: int, lag: int) -> tuple[slice, slice]:
    reference_start = max(0, -lag)
    reference_end = min(reference_size, observed_size - lag)
    count = max(0, reference_end - reference_start)
    observed_start = reference_start + lag
    return (
        slice(reference_start, reference_start + count),
        slice(observed_start, observed_start + count),
    )


def normalized_correlation(
    reference: np.ndarray,
    observed: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    # scipy.signal.correlate(observed, reference) uses the same convention as
    # AudioLinkDSP: r[lag] = sum(reference[i] * observed[i + lag]).
    numerator = signal.correlate(observed, reference, mode="full", method="fft")
    lags = signal.correlation_lags(observed.size, reference.size, mode="full")
    values = np.zeros_like(numerator, dtype=np.float64)
    for index, lag_value in enumerate(lags):
        reference_slice, observed_slice = overlap(reference.size, observed.size, int(lag_value))
        denominator = np.sqrt(
            np.dot(reference[reference_slice], reference[reference_slice])
            * np.dot(observed[observed_slice], observed[observed_slice])
        )
        if denominator > np.finfo(float).tiny:
            values[index] = np.clip(numerator[index] / denominator, -1.0, 1.0)
    return lags, values


def parabolic_offset(values: np.ndarray, index: int) -> float | None:
    if index == 0 or index + 1 == values.size:
        return None
    left, center, right = np.abs(values[index - 1 : index + 2])
    denominator = left - 2 * center + right
    if denominator >= -np.finfo(float).eps:
        return None
    offset = 0.5 * (left - right) / denominator
    return float(offset) if np.isfinite(offset) and abs(offset) <= 1 else None


def run_swift(args: argparse.Namespace, reference: Path, observed: Path, output: Path) -> None:
    command = [
        "swift",
        "run",
        "--package-path",
        str(args.workspace / "Packages" / "AudioLinkDSP"),
        "AudioLinkCorrelationTool",
        str(reference),
        str(observed),
        "--method",
        "fft",
        "--min-lag",
        str(args.min_lag),
        "--max-lag",
        str(args.max_lag),
        "--sequence",
        "searchedRange",
        "--json-output",
        str(output),
    ]
    subprocess.run(command, cwd=args.workspace, check=True)


def swift_values(report: dict) -> tuple[int, float, float | None, np.ndarray, np.ndarray]:
    correlation = report["result"]["correlation"]
    peak = correlation["primaryPeak"]
    encoded_lag = peak["lag"]
    lag = int(encoded_lag["rawValue"] if isinstance(encoded_lag, dict) else encoded_lag)
    value = float(peak["value"])
    fractional = peak.get("fractionalLag")
    sequence = correlation["sequence"]
    first_lag = int(sequence["firstLag"])
    values = np.asarray(sequence["values"], dtype=np.float64)
    lags = np.arange(first_lag, first_lag + values.size)
    return lag, value, None if fractional is None else float(fractional), lags, values


def main() -> int:
    args = parse_args()
    expected_delay: int | None = None
    if args.generate_fixture:
        reference_path, observed_path, expected_delay = write_fixture(args.generate_fixture)
    else:
        if args.reference is None or args.observed is None:
            raise ValueError("Provide --reference and --observed, or use --generate-fixture.")
        reference_path, observed_path = args.reference, args.observed

    swift_json = args.swift_json
    if args.run_swift:
        swift_json = swift_json or observed_path.with_suffix(".swift-correlation.json")
        run_swift(args, reference_path, observed_path, swift_json)

    reference_rate, reference = normalized_mono(reference_path)
    observed_rate, observed = normalized_mono(observed_path)
    if reference_rate != observed_rate:
        raise ValueError("Reference and observed sample rates differ.")
    lags, values = normalized_correlation(reference, observed)
    selected = (lags >= args.min_lag) & (lags <= args.max_lag)
    selected_lags = lags[selected]
    selected_values = values[selected]
    peak_index = int(np.argmax(np.abs(selected_values)))
    numpy_lag = int(selected_lags[peak_index])
    numpy_peak = float(selected_values[peak_index])
    offset = parabolic_offset(selected_values, peak_index)
    numpy_fractional = None if offset is None else numpy_lag + offset

    print(f"sample_rate={reference_rate}")
    print(f"scipy_integer_lag={numpy_lag}")
    print(f"scipy_fractional_lag={numpy_fractional}")
    print(f"scipy_normalized_peak={numpy_peak:.9f}")
    if expected_delay is not None and numpy_lag != expected_delay:
        print(f"FAIL: fixture expected lag {expected_delay}", file=sys.stderr)
        return 1

    swift_sequence_lags: np.ndarray | None = None
    swift_sequence_values: np.ndarray | None = None
    if swift_json:
        with swift_json.open("r", encoding="utf-8") as stream:
            report = json.load(stream)
        swift_lag, swift_peak, swift_fractional, swift_sequence_lags, swift_sequence_values = swift_values(report)
        sequence_mask = (selected_lags >= swift_sequence_lags[0]) & (
            selected_lags <= swift_sequence_lags[-1]
        )
        numpy_sequence = selected_values[sequence_mask]
        maximum_sequence_error = float(np.max(np.abs(numpy_sequence - swift_sequence_values)))
        print(f"swift_integer_lag={swift_lag}")
        print(f"swift_fractional_lag={swift_fractional}")
        print(f"swift_normalized_peak={swift_peak:.9f}")
        print(f"maximum_sequence_error={maximum_sequence_error:.9g}")
        failures = []
        if swift_lag != numpy_lag:
            failures.append("integer lag differs")
        if abs(swift_peak - numpy_peak) > args.peak_tolerance:
            failures.append("normalized peak differs")
        if maximum_sequence_error > args.peak_tolerance:
            failures.append("correlation sequence differs")
        if swift_fractional is not None and numpy_fractional is not None:
            if abs(swift_fractional - numpy_fractional) > args.fractional_lag_tolerance:
                failures.append("fractional lag differs")
        if failures:
            print("FAIL: " + ", ".join(failures), file=sys.stderr)
            return 1

    if args.plot:
        figure, axes = plt.subplots(2, 1, figsize=(12, 7), constrained_layout=True)
        axes[0].plot(reference, linewidth=0.6, label="Reference")
        axes[0].plot(observed, linewidth=0.5, alpha=0.7, label="Observed")
        axes[0].set(title="Correlation fixture", xlabel="Frame", ylabel="Amplitude")
        axes[0].legend()
        axes[1].plot(selected_lags, selected_values, label="SciPy", linewidth=1.2)
        if swift_sequence_lags is not None and swift_sequence_values is not None:
            axes[1].plot(
                swift_sequence_lags,
                swift_sequence_values,
                linestyle="--",
                label="Swift",
                linewidth=0.8,
            )
        axes[1].set(title="Normalized linear cross-correlation", xlabel="Lag (samples)")
        axes[1].legend()
        figure.savefig(args.plot, dpi=160)
        plt.close(figure)
        print(f"plot={args.plot}")

    if swift_json:
        print("PASS: SciPy and AudioLinkDSP correlation agree")
    else:
        print("PASS: SciPy reference correlation computed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
