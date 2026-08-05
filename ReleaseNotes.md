Major release.

- Added a native macOS SwiftUI workflow for reference-versus-recording WAV latency analysis.
- Added deterministic logarithmic and linear sweeps, chirps, MLS, impulse, silence, and seeded noise generation.
- Added PCM 16/24/32-bit and IEEE Float32 WAV import with explicit preprocessing and safe decoded-size limits.
- Added direct and Accelerate FFT cross-correlation with signed lag conventions, search windows, peak candidates, and fractional interpolation.
- Added explainable quality levels, confidence diagnostics, clipping/noise/truncation checks, ambiguity detection, and structured warnings.
- Added waveform, correlation, and peak-detail visualization models with bounded downsampling and PNG export.
- Added privacy-first SQLite history, repeat-measurement statistics, calibration profiles, clock-drift estimation, and processing logs.
- Added same-Mac real-time loopback orchestration, Core Audio capability models, bounded realtime capture storage, and a native iOS companion target.
- Added Bonjour/LAN protocol foundations, explicit pairing, chunked transfer, clock observations, and uncertainty-aware distributed measurement foundations.
- Added reporting in JSON, CSV, HTML, PDF, and PNG plus the checksummed `.audiolinkbundle` format.
- Added the `audiolink` CLI, localhost-only automation API, batch plans, shell completions, and Python examples.
- Added adaptive planning, spatial IR, device benchmark, plugin, and signal-path foundations.
- Added Python reference validation, blind cases, benchmarks, architecture checks, fault-injection notes, and privacy scanning.
- Switched the project license to Mozilla Public License 2.0.
- Documented hardware, hostile-LAN, third-party Audio Unit, signing, notarization, and validation limitations.
