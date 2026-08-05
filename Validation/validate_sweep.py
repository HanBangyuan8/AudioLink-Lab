#!/usr/bin/env python3
"""Plot and numerically validate an AudioLink logarithmic or linear sweep WAV."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.io import wavfile
from scipy.signal import hilbert, savgol_filter, spectrogram


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot waveform/spectrogram and validate a Swift-exported sweep trajectory."
    )
    parser.add_argument("wav", type=Path, help="PCM or IEEE Float WAV exported by AudioLinkDSP")
    parser.add_argument("--kind", choices=("logarithmic", "linear"), default="logarithmic")
    parser.add_argument("--start-frequency", type=float, default=20.0)
    parser.add_argument("--end-frequency", type=float, default=20_000.0)
    parser.add_argument("--duration", type=float, default=2.0, help="Active signal duration in seconds")
    parser.add_argument("--pre-roll", type=float, default=0.0, help="Leading silence in seconds")
    parser.add_argument("--direction", choices=("ascending", "descending"), default="ascending")
    parser.add_argument("--output", type=Path, help="Output PNG; defaults beside the WAV")
    parser.add_argument("--max-median-relative-error", type=float, default=0.08)
    parser.add_argument("--max-p95-relative-error", type=float, default=0.30)
    return parser.parse_args()


def normalized_mono(samples: np.ndarray) -> np.ndarray:
    if samples.ndim == 2:
        samples = samples[:, 0]
    if np.issubdtype(samples.dtype, np.integer):
        maximum = max(abs(np.iinfo(samples.dtype).min), np.iinfo(samples.dtype).max)
        return samples.astype(np.float64) / float(maximum)
    return samples.astype(np.float64)


def expected_frequency(
    times: np.ndarray,
    duration: float,
    start: float,
    end: float,
    kind: str,
) -> np.ndarray:
    progress = np.clip(times / duration, 0.0, 1.0)
    if kind == "logarithmic":
        return start * np.exp(np.log(end / start) * progress)
    return start + (end - start) * progress


def estimate_instantaneous_frequency(samples: np.ndarray, sample_rate: int) -> np.ndarray:
    phase = np.unwrap(np.angle(hilbert(samples)))
    instantaneous = np.gradient(phase) * sample_rate / (2.0 * np.pi)
    window = max(5, int(round(sample_rate * 0.01)) | 1)
    if window >= samples.size:
        window = samples.size if samples.size % 2 == 1 else samples.size - 1
    if window >= 5:
        instantaneous = savgol_filter(instantaneous, window_length=window, polyorder=2)
    return instantaneous


def main() -> int:
    args = parse_args()
    sample_rate, raw = wavfile.read(args.wav)
    mono = normalized_mono(raw)
    start_frame = int(round(args.pre_roll * sample_rate))
    active_frames = int(round(args.duration * sample_rate))
    stop_frame = start_frame + active_frames
    if start_frame < 0 or active_frames < 8 or stop_frame > mono.size:
        raise ValueError("Requested active range does not fit inside the WAV file.")
    active = mono[start_frame:stop_frame]

    start_frequency = args.start_frequency
    end_frequency = args.end_frequency
    if args.direction == "descending":
        start_frequency, end_frequency = end_frequency, start_frequency
    if start_frequency <= 0 or end_frequency <= 0:
        raise ValueError("Sweep validation requires positive frequencies.")

    times = np.arange(active.size, dtype=np.float64) / sample_rate
    expected = expected_frequency(
        times,
        args.duration,
        start_frequency,
        end_frequency,
        args.kind,
    )
    estimated = estimate_instantaneous_frequency(active, sample_rate)

    # Hilbert estimates are least reliable at signal edges because the analytic
    # transform has no samples outside the recording. Validate the central 80%.
    evaluation = (times >= args.duration * 0.10) & (times <= args.duration * 0.90)
    relative_error = np.abs(estimated[evaluation] - expected[evaluation]) / expected[evaluation]
    relative_error = relative_error[np.isfinite(relative_error)]
    median_error = float(np.median(relative_error))
    p95_error = float(np.percentile(relative_error, 95))

    segment = min(4096, active.size)
    overlap = segment * 3 // 4
    frequencies, spectrogram_times, spectrum = spectrogram(
        active,
        fs=sample_rate,
        window="hann",
        nperseg=segment,
        noverlap=overlap,
        mode="magnitude",
    )
    decibels = 20 * np.log10(np.maximum(spectrum, np.finfo(float).tiny))
    output = args.output or args.wav.with_suffix(".validation.png")

    figure, axes = plt.subplots(3, 1, figsize=(12, 10), constrained_layout=True)
    axes[0].plot(times, active, linewidth=0.6)
    axes[0].set(title="Waveform", xlabel="Time (s)", ylabel="Amplitude", ylim=(-1.05, 1.05))

    mesh = axes[1].pcolormesh(spectrogram_times, frequencies, decibels, shading="auto")
    axes[1].plot(
        spectrogram_times,
        expected_frequency(
            spectrogram_times,
            args.duration,
            start_frequency,
            end_frequency,
            args.kind,
        ),
        color="white",
        linewidth=1.2,
        label="Expected trajectory",
    )
    axes[1].set(
        title="Spectrogram",
        xlabel="Time (s)",
        ylabel="Frequency (Hz)",
        yscale="log",
        ylim=(max(10, min(start_frequency, end_frequency) / 2), sample_rate / 2),
    )
    axes[1].legend(loc="upper left")
    figure.colorbar(mesh, ax=axes[1], label="Magnitude (dB)")

    axes[2].plot(times, expected, label="Expected", linewidth=1.4)
    axes[2].plot(times, estimated, label="Hilbert estimate", linewidth=0.7, alpha=0.8)
    axes[2].set(
        title=f"Frequency track: median error {median_error:.3%}, p95 {p95_error:.3%}",
        xlabel="Time (s)",
        ylabel="Frequency (Hz)",
        yscale="log" if args.kind == "logarithmic" else "linear",
        ylim=(max(10, min(start_frequency, end_frequency) / 2), sample_rate / 2),
    )
    axes[2].legend(loc="upper left")
    figure.savefig(output, dpi=160)
    plt.close(figure)

    print(f"sample_rate={sample_rate} frames={active.size}")
    print(f"median_relative_error={median_error:.6f}")
    print(f"p95_relative_error={p95_error:.6f}")
    print(f"plot={output}")
    if median_error > args.max_median_relative_error or p95_error > args.max_p95_relative_error:
        print("FAIL: frequency trajectory exceeds configured error limits", file=sys.stderr)
        return 1
    print("PASS: sweep frequency trajectory is within configured error limits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
