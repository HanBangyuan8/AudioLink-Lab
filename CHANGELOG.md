# Changelog

## v1.0.0 - 2026-08-05

Initial public release.

- Added a native macOS SwiftUI workflow for reference-versus-recording WAV latency analysis.
- Added deterministic logarithmic and linear sweeps, chirps, MLS, impulse, silence, and seeded noise generation.
- Added PCM 16/24/32-bit and IEEE Float32 WAV import with explicit preprocessing and safe decoded-size limits.
- Added direct and Accelerate FFT cross-correlation with signed lag conventions, search windows, peak candidates, and fractional interpolation.
- Added explainable quality levels, confidence diagnostics, clipping/noise/truncation checks, ambiguity detection, and structured warnings.
- Added waveform, correlation, and peak-detail visualization models with bounded downsampling and PNG export.
- Added privacy-first SQLite history, repeat-measurement statistics, calibration profiles, clock-drift estimation, and processing logs.
- Added same-Mac real-time loopback orchestration, Core Audio capability models, and bounded realtime capture storage.
- Added Bonjour/LAN protocol foundations, explicit pairing, chunked transfer, clock observations, and a native iOS companion target.
- Added reporting in JSON, CSV, HTML, PDF, and PNG plus the checksummed `.audiolinkbundle` format.
- Added the `audiolink` CLI, localhost-only automation API, batch plans, shell completions, and Python examples.
- Added adaptive planning, spatial IR, distributed measurement, device benchmark, plugin, and signal-path foundations.
- Added Python reference validation, blind cases, benchmarks, architecture checks, fault-injection notes, and privacy scanning.
- Licensed under the Mozilla Public License 2.0.

## v0.9.0

Release-audit baseline.

- Centralized app, build, algorithm, protocol, report, bundle, automation, and database version metadata.
- Added the independent DSP, architecture, privacy, concurrency, and security review documents.
- Added generated validation corpora, blind fixtures, benchmark scripts, and release packaging support.
- Added migration backups, bounded bundle validation, importer limits, cancellation cleanup, and realtime callback hardening.

## v0.1.0

Development release.

- Added initial milestones for signal generation, WAV import, correlation, quality analysis, visualization, storage, realtime measurement, networking, mobile companion, calibration, drift, and reporting.
