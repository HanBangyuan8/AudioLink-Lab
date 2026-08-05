#!/usr/bin/env python3
"""Run the generated corpus through SciPy and AudioLinkDSP and summarize it.

This intentionally fails closed: a valid case must agree on integer lag and
normalized peak, while an invalid case must be rejected by Swift.  The output
is a small JSON/Markdown artifact suitable for CI; WAV files remain generated
and disposable.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

try:
    import numpy as np
    from scipy import signal
    from scipy.io import wavfile
except ModuleNotFoundError as error:
    raise SystemExit("Validation dependencies are missing. Install with: python3 -m pip install -r Validation/requirements.txt") from error


def read_mono(path: Path) -> tuple[int, np.ndarray]:
    rate, samples = wavfile.read(path)
    if samples.ndim == 2:
        samples = samples[:, 0]
    if np.issubdtype(samples.dtype, np.integer):
        scale = max(abs(np.iinfo(samples.dtype).min), np.iinfo(samples.dtype).max)
        samples = samples.astype(np.float64) / float(scale)
    else:
        samples = samples.astype(np.float64)
    return int(rate), samples


def overlap(reference_size: int, observed_size: int, lag: int) -> tuple[slice, slice]:
    reference_start = max(0, -lag)
    end = min(reference_size, observed_size - lag)
    count = max(0, end - reference_start)
    return slice(reference_start, reference_start + count), slice(reference_start + lag, reference_start + lag + count)


def reference_correlation(reference: np.ndarray, observed: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    numerator = signal.correlate(observed, reference, mode="full", method="fft")
    lags = signal.correlation_lags(observed.size, reference.size, mode="full")
    values = np.zeros_like(numerator, dtype=np.float64)
    for index, lag in enumerate(lags):
        reference_slice, observed_slice = overlap(reference.size, observed.size, int(lag))
        denominator = np.sqrt(np.dot(reference[reference_slice], reference[reference_slice]) * np.dot(observed[observed_slice], observed[observed_slice]))
        if denominator > np.finfo(float).tiny:
            values[index] = np.clip(numerator[index] / denominator, -1.0, 1.0)
    return lags, values


def run_case(binary: Path, root: Path, case: dict, json_path: Path) -> tuple[int, str, dict | None]:
    reference = root / case["reference"]
    observed = root / case["observed"]
    command = [str(binary), str(reference), str(observed), "--method", "fft", "--min-lag", str(case["min_lag"]), "--max-lag", str(case["max_lag"]), "--polarity", "absolute", "--sequence", "searchedRange", "--channel", str(case.get("channel", 0)), "--json-output", str(json_path)]
    completed = subprocess.run(command, cwd=root, text=True, capture_output=True)
    report = None
    if json_path.exists():
        report = json.loads(json_path.read_text(encoding="utf-8"))
    return completed.returncode, completed.stderr.strip() or completed.stdout.strip(), report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, default=Path("Validation/results"))
    parser.add_argument("--profile", choices=("quick", "full"), default="quick")
    args = parser.parse_args()
    root = args.workspace.resolve()
    generated = root / "Validation" / "generated"
    subprocess.run([sys.executable, str(root / "Validation" / "generate_validation_dataset.py"), "--output", str(generated), "--profile", args.profile], cwd=root, check=True)
    subprocess.run(["swift", "build", "--package-path", str(root / "Packages" / "AudioLinkDSP"), "-c", "release", "-Xswiftc", "-warnings-as-errors"], cwd=root, check=True)
    bin_dir = subprocess.check_output(["swift", "build", "--package-path", str(root / "Packages" / "AudioLinkDSP"), "-c", "release", "--show-bin-path"], cwd=root, text=True).strip()
    binary = Path(bin_dir) / "AudioLinkCorrelationTool"
    manifest = json.loads((generated / "manifest.json").read_text(encoding="utf-8"))
    args.output.mkdir(parents=True, exist_ok=True)
    results: list[dict] = []
    failures = 0
    with tempfile.TemporaryDirectory(prefix="audiolink-validation-", dir=args.output) as temp:
        temp_root = Path(temp)
        for case in manifest["cases"]:
            swift_json = temp_root / f"{case['name']}.json"
            returncode, error, report = run_case(binary, generated, case, swift_json)
            expected = case["expected"]
            result = {"name": case["name"], "category": case["category"], "expected": expected, "swiftExitCode": returncode}
            if expected == "invalid":
                result["passed"] = returncode != 0
                result["detail"] = error if returncode != 0 else "Swift unexpectedly returned a result"
            elif report is None or returncode != 0:
                result["passed"] = False
                result["detail"] = error or "Swift produced no JSON report"
            else:
                rate, reference = read_mono(generated / case["reference"])
                observed_rate, observed = read_mono(generated / case["observed"])
                lags, values = reference_correlation(reference, observed)
                selected = (lags >= case["min_lag"]) & (lags <= case["max_lag"])
                selected_lags, selected_values = lags[selected], values[selected]
                index = int(np.argmax(np.abs(selected_values)))
                numpy_lag = int(selected_lags[index])
                numpy_peak = float(selected_values[index])
                peak = report["result"]["correlation"]["primaryPeak"]
                swift_lag = int(peak["lag"]["rawValue"] if isinstance(peak["lag"], dict) else peak["lag"])
                swift_peak = float(peak["value"])
                validity = report["result"]["correlation"].get("diagnostics", {}).get("validity")
                result.update({"sampleRate": rate, "scipyLag": numpy_lag, "swiftLag": swift_lag, "scipyPeak": numpy_peak, "swiftPeak": swift_peak, "peakError": abs(numpy_peak - swift_peak), "validity": validity})
                lag_matches = case["expected_lag"] is None or abs(swift_lag - case["expected_lag"]) <= (2 if case["category"] == "fractionalDelay" else 0)
                scipy_matches = abs(swift_lag - numpy_lag) <= 1
                peak_matches = abs(numpy_peak - swift_peak) <= 5e-3
                expected_validity = expected == "ambiguous"
                ambiguity_matches = (validity == "ambiguous") if expected_validity else True
                result["passed"] = bool(lag_matches and scipy_matches and peak_matches and ambiguity_matches)
                if not result["passed"]:
                    result["detail"] = "; ".join([f"expected lag {case['expected_lag']}" if not lag_matches else "", "SciPy/Swift lag mismatch" if not scipy_matches else "", "peak mismatch" if not peak_matches else "", "ambiguity was not reported" if not ambiguity_matches else ""]).strip("; ")
            if not result["passed"]:
                failures += 1
            results.append(result)
    summary = {"formatVersion": 1, "profile": args.profile, "caseCount": len(results), "passed": len(results) - failures, "failed": failures, "cases": results}
    json_path = args.output / "validation-summary.json"
    json_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    lines = ["# AudioLink validation summary", "", f"Profile: `{args.profile}`", f"Passed: **{summary['passed']} / {summary['caseCount']}**", "", "| Case | Category | Result | Swift lag | SciPy lag | Validity |", "|---|---|---:|---:|---:|---|"]
    for item in results:
        lines.append(f"| {item['name']} | {item['category']} | {'PASS' if item['passed'] else 'FAIL'} | {item.get('swiftLag', '—')} | {item.get('scipyLag', '—')} | {item.get('validity', '—')} |")
    (args.output / "validation-summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Validation: {summary['passed']}/{summary['caseCount']} passed; summary={json_path}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
