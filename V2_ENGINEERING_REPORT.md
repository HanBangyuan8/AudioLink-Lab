# AudioLink Lab v2 engineering report

Status: **v2.0-ready: no**. This release adds the v2 platform foundations and
headless interfaces while keeping the existing v1 application buildable. It
does not silently promote hardware-dependent modules to headless support.

## Architecture

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

## Added components

- `AudioLinkAutomation`: CLI, file-analysis façade, batch plan loader, and
  loopback-only token-authenticated HTTP router.
- `AudioLinkBundle`: directory `.audiolinkbundle` writer/validator with manifest,
  checksums, size limits, traversal and symlink checks, and optional content.
- `AudioLinkPlatform`: module descriptors, JSONValue-backed result envelope,
  provenance, capability declarations, and resource-locked jobs.
- CLI reference, automation security notes, bundle format, examples and shell
  completions.

## Schema and migration

The external bundle schema is `1.0`; automation API and module envelope are
`1.0`. Existing report schema remains `1.0` and SQLite remains schema `5`.
No v1 database rows are rewritten by these additions. A future v2 migration
still needs an explicit backup/rollback wrapper before changing the database.

## Automated verification

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

## Manual validation still required

- Fresh install and v1 upgrade migration rehearsal.
- macOS TCC microphone/file access and GUI-first authorization.
- Real Core Audio devices, plugin helper crashes, DAW paths, and distributed
  nodes.
- Local API inspection from a second same-user process, shutdown, and token
  rotation.
- Opening bundles containing reports/charts in the GUI without executing HTML.
- Large bundle and long batch memory/throughput checks.

## Performance baseline

- The final package test matrix completed in roughly 12 seconds on this Apple
  Silicon development host; the macOS app tests completed in about 0.6 seconds.
- Bundle and automation targeted suites each completed in under 0.02 seconds
  for their small fixtures.
- CLI smoke generation/analyze includes a SwiftPM build, so its wall time is
  not a representative DSP benchmark.
- Peak memory and allocation counters were not instrumented in this pass;
  long-duration audio, large bundles, and large batch throughput remain
  unverified release measurements.

## Blocking items

1. Existing hardware, plugin, DAW, spatial, and distributed modules need concrete
   `MeasurementModule` adapters before they can honestly be advertised as
   executable headless modules.
2. v2 database/report/configuration migrations and backup/rollback are not yet
   implemented.
3. No signing, notarization, App Store review, or third-party plugin security
   certification was performed.

Recommended label: keep the current metadata unchanged and publish this work as
an automation/platform alpha, not as v2.0-ready.
