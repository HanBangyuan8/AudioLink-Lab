# AudioLink Lab developer and validation reference

This reference consolidates CLI, validation, release, performance, and v2 engineering documentation.


---

<!-- Consolidated topic section. -->

## AudioLink CLI reference

The `audiolink` executable is a macOS-only, headless façade over the same
`AudioLinkDSP`, `AudioLinkRealtime`, `AudioLinkReporting`, and storage APIs used
by the application. It does not contain a second correlation implementation.

### Exit codes

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

### Examples

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

### Plan schema 1.0

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


---

<!-- Consolidated topic section. -->

## Validation corpus

`Validation/generate_validation_dataset.py` creates a deterministic, disposable
corpus with integer and fractional delays, gain, polarity, white/pink noise,
clipping, echoes/reverberation, truncation, sample-rate drift, periodic
ambiguity, stereo mismatch, silence, 96 kHz, and a full-profile long input.

`Validation/run_validation.py` runs each pair through the release-built
`AudioLinkCorrelationTool`, calculates the same linear normalized correlation
with NumPy/SciPy, checks integer lag/peak agreement, and expects invalid or
ambiguous outcomes where appropriate. It writes `validation-summary.json` and
`validation-summary.md` and exits non-zero for a mismatch.

The truncation fixture deliberately requires an `ambiguous` diagnostic rather
than an exact lag: a partial recording can contain a plausible but non-unique
peak, so reporting the warning is the tested behavior. The stereo-mismatch
fixture is a mono/stereo configuration error and must be rejected cleanly
(exit code 2) until the caller explicitly downmixes or selects compatible
channels.

The Python environment is optional and never used by the app:

```bash
python3 -m pip install -r Validation/requirements.txt
python3 Validation/run_validation.py --profile quick
python3 Validation/run_validation.py --profile full --output Validation/results/full
```

Tolerance is intentionally explicit: one sample for cross-implementation peak
location, 5e-3 for normalized peak, and a small additional allowance for the
fractional-delay fixture. Acoustic quality labels are expected categories, not
ground truth about a physical room.

The v1.1 alpha package tests additionally cover deterministic planner rule
selection, synthetic IR extraction/metric validity, sparse-map warnings, and
multi-node readiness/stale-session rejection. No real room, hardware matrix,
DAW, or more-than-two-device result is represented by these automated tests.

### Independent DSP review

`Validation/Reference/reference_algorithms.py` re-implements the equations
without importing Swift code. `Validation/BlindCases` generates 100 deterministic
WAV-only cases and reveals the exact truth manifest only after Swift analysis.
This is the preferred numerical audit path. It requires NumPy and SciPy from
`Validation/requirements.txt`; a missing environment is an explicit
**unverified** result, never a successful validation.


---

<!-- Consolidated topic section. -->

## v1.0 release audit

This document records the evidence available for the release candidate. It is
deliberately a checklist, not a claim that unavailable hardware has been tested.

### Findings and actions

| Area | Evidence / risk | Action or status |
| --- | --- | --- |
| Package boundaries | Core/DSP/Storage/Realtime/Networking/Reporting are independent Swift packages; apps consume them | Verified by manifests and clean package builds |
| UI isolation | SwiftUI targets contain view models/adapters; correlation, quality, import, storage, and transport remain in packages | Verified by dependency graph review |
| Concurrency | Shared mutable stores are actors; realtime/network callbacks are isolated; no global business singleton found | Automated tests pass; Instruments race check not available here |
| `@unchecked Sendable` | Used only at framework/SQLite/FFI boundaries and documented by the owning type; it remains a review hotspot | No blanket removal; run Thread Sanitizer/Instruments before distribution |
| Force unwraps | No `try!`, `as!`, `fatalError`, or `preconditionFailure` in app/package sources | Verified with repository scan |
| File handles/temp files | Importer and transfer paths use scoped resources/deferred cleanup; transfer uses `.part` plus atomic move | Unit coverage passes; disk-full and interruption require manual/OS fault injection |
| SQLite | Full mutex, foreign keys, busy timeout, WAL, transaction rollback, v1→v5 migration tests | Verified by storage tests; damaged-file recovery remains a future tool |
| Units/overflow | Sample counts and rates are typed; lag ranges use reporting-overflow arithmetic | Verified by Core/DSP tests; long-run hardware counters need soak testing |
| Error visibility | Structured errors map to user-facing text in Mac/iOS state controllers | Verified in feature tests; review new OS-specific errors during hardware checklist |
| Device monitoring | Core Audio snapshot failures now terminate the event stream instead of being silently ignored | Fixed; caller must refresh/retry and can surface the failure |
| Privacy | History/report builders omit absolute paths/bookmarks/audio by default | Verified by report/storage tests and the Security and Data reference |
| Network security | Pairing, token, replay, size, and checksum guards exist; TCP is not encrypted | Explicit release blocker for hostile-LAN use; do not claim TLS |
| Long input memory | 60 s full benchmark reached ~1.16 GiB peak RSS during FFT correlation | Known v1 limit; multi-minute support requires streaming/coarse-to-fine work |
| Versioning | Release metadata is centralized; SQLite and report schemas are independently versioned | App bundle script now accepts version/build overrides |
| Signing | Local bundle is ad-hoc/unsigned | Developer ID, provisioning, archive, notarization are not verified here |
| Release flow | `Scripts/release.sh --skip-validation` generated a versioned ZIP, SHA-256 file, and manifest; checksum verified | Validation was intentionally skipped on this host because NumPy/SciPy are absent |

### Required manual checks before calling the v1.0 package production-ready

1. Real Mac loopback and speaker/microphone measurements at 44.1/48/96 kHz.
2. USB, Bluetooth, aggregate, and route-disconnect/reconnect tests.
3. 100-run soak, cancellation at every phase, sleep/wake, interruption, and
   disk-full behavior.
4. Two physical iPhones: pairing, role reversal, transfer interruption, route
   changes, lock-screen/phone-call behavior, and cleanup policy.
5. Thread Sanitizer/Address Sanitizer/Instruments leak and allocation passes.
6. Developer ID signing, notarization, clean install, upgrade, and rollback.

The repository can publish a `v1.0.0` source/package tag with these limitations
visible in the release notes, but the package must not be described as
hardware-certified or hostile-network-ready until these checks are complete.


---

<!-- Consolidated topic section. -->

## AudioLink Lab v2 engineering report

Status: **v2.0-ready: no**. This release adds the v2 platform foundations and
headless interfaces while keeping the existing v1 application buildable. It
does not silently promote hardware-dependent modules to headless support.

### Architecture

```text
SwiftUI macOS / iOS       audiolink CLI       localhost automation (opt-in)
          \                      |                       /
           MeasurementPlatform: descriptors, envelope, job queue
             |                  |                    |
        Core/DSP        Realtime/Plugin/Path      Bundle/Reporting/Storage
```

`MeasurementModuleDescriptor`, `MeasurementResultEnvelope`, and
`MeasurementJobQueue` are internal, versioned platform primitives. The queue is
FIFO and conservatively permits one active resource set at a time, preventing
shared audio-device, helper, or coordinator conflicts. Cancellation propagates
to the module task and timeout cleanup releases the active resource set.

### Added components

- `AudioLinkAutomation`: CLI, file-analysis façade, batch plan loader, and
  loopback-only token-authenticated HTTP router.
- `AudioLinkBundle`: directory `.audiolinkbundle` writer/validator with manifest,
  checksums, size limits, traversal and symlink checks, and optional content.
- `AudioLinkPlatform`: module descriptors, JSONValue-backed result envelope,
  provenance, capability declarations, and resource-locked jobs.
- CLI reference, automation security notes, bundle format, examples and shell
  completions.

### Schema and migration

The external bundle schema is `1.0`; automation API and module envelope are
`1.0`. Existing report schema remains `1.0` and SQLite remains schema `5`.
No v1 database rows are rewritten by these additions. A future v2 migration
still needs an explicit backup/rollback wrapper before changing the database.

### Automated verification

Passing final regression tests:

- Full `Scripts/test-packages.sh`: 227 tests across the 14 Swift packages and
  the mobile host target, with zero failures.
- macOS app test target: 22 tests, zero failures.
- Focused security/platform reruns: AudioLinkAutomation 6 and
  AudioLinkPlatform 3, zero failures.
- Post-baseline Bundle integrity rerun: 4 tests, zero failures.
- `Scripts/build-all.sh`: all packages plus macOS and mobile host targets build
  with `-warnings-as-errors`.
- iOS simulator compile: passed; Xcode emits its existing cross-sysroot clang
  warning for the host companion build.
- CLI smoke: `generate-signal` and `analyze-files` produced versioned JSON and
  a valid 48 kHz WAV.
- CLI `validate` successfully checked the checked-in anonymous bundle fixture
  and its SHA-256 inventory.
- CLI SIGINT/SIGTERM handling now requests cooperative cancellation and maps
  cancellation to exit code 5; real hardware restoration remains the adapter's
  responsibility.

The new CLI builds with Swift 6 warnings-as-errors and a smoke test successfully
generated a 48 kHz WAV and emitted JSON-only stdout.

### Manual validation still required

- Fresh install and v1 upgrade migration rehearsal.
- macOS TCC microphone/file access and GUI-first authorization.
- Real Core Audio devices, plugin helper crashes, DAW paths, and distributed
  nodes.
- Local API inspection from a second same-user process, shutdown, and token
  rotation.
- Opening bundles containing reports/charts in the GUI without executing HTML.
- Large bundle and long batch memory/throughput checks.

### Performance baseline

- The final package test matrix completed in roughly 12 seconds on this Apple
  Silicon development host; the macOS app tests completed in about 0.6 seconds.
- Bundle and automation targeted suites each completed in under 0.02 seconds
  for their small fixtures.
- CLI smoke generation/analyze includes a SwiftPM build, so its wall time is
  not a representative DSP benchmark.
- Peak memory and allocation counters were not instrumented in this pass;
  long-duration audio, large bundles, and large batch throughput remain
  unverified release measurements.

### Blocking items

1. Existing hardware, plugin, DAW, spatial, and distributed modules need concrete
   `MeasurementModule` adapters before they can honestly be advertised as
   executable headless modules.
2. v2 database/report/configuration migrations and backup/rollback are not yet
   implemented.
3. No signing, notarization, App Store review, or third-party plugin security
   certification was performed.

Recommended label: keep the current metadata unchanged and publish this work as
an automation/platform alpha, not as v2.0-ready.
