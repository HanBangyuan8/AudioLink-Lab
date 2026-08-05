#!/usr/bin/env python3
"""Run Swift correlation against blind cases, then reveal the truth."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path, default=Path("Validation/results/blind-summary.json"))
    args = parser.parse_args()
    root = args.workspace.resolve()
    generated = root / "Validation" / "blind-generated"
    generator = root / "Validation" / "BlindCases" / "generate_blind_cases.py"
    try:
        subprocess.run([sys.executable, str(generator), "--output", str(generated)], cwd=root, check=True)
    except subprocess.CalledProcessError as error:
        print(
            "Blind validation is unverified: the case generator could not run "
            "(install Validation/requirements.txt first).",
            file=sys.stderr,
        )
        return 2
    binary = args.binary
    if binary is None:
        subprocess.run(["swift", "build", "--package-path", str(root / "Packages" / "AudioLinkDSP"), "-c", "release", "-Xswiftc", "-warnings-as-errors"], cwd=root, check=True)
        bin_dir = subprocess.check_output(["swift", "build", "--package-path", str(root / "Packages" / "AudioLinkDSP"), "-c", "release", "--show-bin-path"], cwd=root, text=True).strip()
        binary = Path(bin_dir) / "AudioLinkCorrelationTool"
    manifest = json.loads((generated / "truth.json").read_text(encoding="utf-8"))
    integer_tolerance = 1
    fractional_tolerance = 0.25
    results: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="audiolink-blind-") as temp:
        for case in manifest["cases"]:
            report_path = Path(temp) / f"{case['name']}.json"
            command = [str(binary), str(generated / case["reference"]), str(generated / case["observed"]), "--method", "fft", "--min-lag", str(case["minimum_lag"]), "--max-lag", str(case["maximum_lag"]), "--sequence", "none", "--json-output", str(report_path)]
            completed = subprocess.run(command, cwd=root, text=True, capture_output=True)
            item = {"name": case["name"], "expected": case["expected_lag"], "swiftExitCode": completed.returncode}
            if completed.returncode == 0 and report_path.exists():
                report = json.loads(report_path.read_text(encoding="utf-8"))
                peak = report["result"]["correlation"]["primaryPeak"]
                lag = int(peak["lag"]["rawValue"] if isinstance(peak["lag"], dict) else peak["lag"])
                fraction = peak.get("fractionalLag")
                item.update({"swiftLag": lag, "swiftFractionalLag": fraction, "integerError": abs(lag - case["integer_expected_lag"]), "fractionalError": abs(float(fraction) - case["expected_lag"]) if fraction is not None else None, "validity": report["result"]["correlation"].get("diagnostics", {}).get("validity")})
                item["passed"] = item["integerError"] <= integer_tolerance and (not case["fractional"] or (item["fractionalError"] is not None and item["fractionalError"] <= fractional_tolerance))
            else:
                item["passed"] = False
                item["detail"] = completed.stderr.strip() or completed.stdout.strip() or "Swift produced no report"
            results.append(item)
    summary = {"formatVersion": 1, "caseCount": len(results), "passed": sum(bool(item["passed"]) for item in results), "failed": sum(not item["passed"] for item in results), "fractionalCases": sum(case["fractional"] for case in manifest["cases"]), "tolerances": {"integerSamples": integer_tolerance, "fractionalSamples": fractional_tolerance}, "cases": results}
    output = args.output if args.output.is_absolute() else root / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Blind validation: {summary['passed']}/{summary['caseCount']} passed; summary={output}")
    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
