# AudioLink CLI reference

The `audiolink` executable is a macOS-only, headless façade over the same
`AudioLinkDSP`, `AudioLinkRealtime`, `AudioLinkReporting`, and storage APIs used
by the application. It does not contain a second correlation implementation.

## Exit codes

| Code | Meaning |
| ---: | --- |
| 0 | Completed successfully |
| 2 | Invalid command or arguments |
| 3 | Missing, unreadable, or ambiguous input/device |
| 4 | Capability is not available in this headless build |
| 5 | Cancelled |
| 6 | Execution or output failure |

`--json` writes one versioned JSON document to stdout. Diagnostics are written
to stderr. Without `--json`, human-readable summaries are allowed. `--quiet`
suppresses those summaries; `--verbose` is reserved for diagnostic expansion.

## Examples

```bash
audiolink generate-signal --output sweep.wav --sample-rate 48000 --duration 2 --json
audiolink analyze-files --reference reference.wav --recording take.wav --json
audiolink analyze-files --reference reference.wav --input-directory takes \
  --output-directory results --continue-on-error --json
audiolink devices --json
audiolink device-info --name "Built-in Microphone" --json
audiolink history --database "$HOME/Library/Application Support/AudioLink/history.sqlite" --json
audiolink export-report --input report.json --format html --output report.html
audiolink validate --input example.audiolinkbundle --json
audiolink run-plan --config plan.json --json
```

`measure-loopback`, `benchmark-device`, `profile-plugin`, and `analyze-path`
are explicit capability boundaries in this first CLI slice. They return exit
code 4 instead of silently choosing hardware or claiming a measurement.

The repository includes `Scripts/audiolink-examples.sh` for repeatable shell
flows:

```bash
Scripts/audiolink-examples.sh batch-analyze reference.wav takes results
Scripts/audiolink-examples.sh generate-signal validation.wav
Scripts/audiolink-examples.sh run-plan Examples/file-analysis-plan.json
Scripts/audiolink-examples.sh export-csv report.json report.csv
Scripts/audiolink-examples.sh ci-file-analysis reference.wav recording.wav
```

`benchmark-device` is included as an explicit, honest capability check and
currently exits with code 4 until a headless hardware adapter is available.

## Plan schema 1.0

Plans are JSON, not YAML, so no third-party parser is required:

```json
{
  "schemaVersion": "1.0",
  "metadata": { "name": "nightly-file-analysis" },
  "measurementMode": "file-analysis",
  "repetitions": 1,
  "exportFormats": ["json"],
  "failurePolicy": "continueOnError",
  "privacy": { "storeAudio": "false" },
  "timeoutSeconds": 300,
  "tasks": [
    {
      "operation": "file-analysis",
      "referenceFile": "reference.wav",
      "recordingFile": "take-01.wav",
      "configuration": { "channel": 0, "method": "automatic", "normalize": true }
    }
  ]
}
```

The plan loader rejects unknown schema versions before starting a task. Device
selectors and permission-sensitive operations remain explicit; an ambiguous
device never falls back to the first match.
