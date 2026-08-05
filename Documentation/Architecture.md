# Architecture

AudioLink Lab uses a package-first architecture so measurement code is shared
by macOS and the native iOS companion without importing SwiftUI.

## Dependency direction

```text
AudioLinkMac ───────────> AudioLinkStorage ──> AudioLinkCore
       ├─────────────────────────────────────> AudioLinkCore
       ├───────────────> AudioLinkDSP ───────> AudioLinkCore
       └──────────> AudioLinkRealtime ───────> AudioLinkDSP
                              └──────────────> AudioLinkCore

AudioLinkDSP ────────────────────────────────> AudioLinkCore
AudioLinkNetworking ─────────────────────────> AudioLinkCore
AudioLinkReporting ──────────────────────────> AudioLinkStorage ──> AudioLinkCore

AudioLinkMobile ─────────────────────────────> AudioLinkCore
       ├─────────────────────────────────────> AudioLinkDSP
       └─────────────────────────────────────> AudioLinkNetworking

AudioLinkAutomation library ─────────────────> AudioLinkDSP / Platform / Core
AudioLinkAutomation CLI ─────────────────────> Realtime / Reporting / Storage / Bundle
AudioLinkPlatform ───────────────────────────> Foundation only
AudioLinkBundle ─────────────────────────────> Foundation/CryptoKit only
```

`AudioLinkCore` owns vocabulary and contracts. It has no UI, audio-device, or
storage dependency. `AudioLinkDSP` is deterministic and accepts value types;
its test-signal layer produces canonical planar Float32 PCM and exposes WAV
export without importing SwiftUI. Optional Python validation remains outside
the package and is never an application runtime dependency.
Audio-file import uses the same PCM type: native WAV decoding and AVFoundation
fallback run off the main actor, while preprocessing is an explicit,
cancellable value-type pipeline with a persistent transformation log.
Delay analysis uses linear overlap-normalized correlation with direct and
Accelerate FFT implementations. FFT setup reuse is bounded per engine and
lock-protected, with no mutable global cache; detailed results remain Core
domain values so storage and future iOS UI can consume them without SwiftUI.
The quality layer consumes those mathematical results plus imported-audio
metrics. Threshold policy is one Codable DSP value, while quality results and
UI-ready presentation values live in Core. No file metadata participates in a
score, and invalid/no-match analysis removes the public delay estimate.
`MeasurementRun.quality` can persist the complete optional assessment without
coupling storage or a future iOS client to the DSP implementation.
`AudioLinkRealtime` owns Core Audio device discovery, route validation,
microphone authorization, controller protocols, AVAudioEngine playback/capture,
and the cancellable measurement state machine. It depends on DSP for generation,
explicit preprocessing, cross-correlation and quality assessment, but does not
depend on SwiftUI or Storage. History is injected through
`RealtimeMeasurementSaving` at the app composition root. `AudioLinkStorage`
provides an actor-owned system
SQLite repository with schema migrations, transactions, privacy-safe history
models, session/run statistics, queries and comparison, plus the lightweight
actor-backed memory store used by foundational tests. `AudioLinkNetworking`
contains the Foundation-only v1 LAN boundary: actor-isolated protocol/session
state, bounded framed transports, Bonjour discovery, explicit pairing/replay
protection, chunked checksum-verified file transfer, and diagnostic clock
observations. It has no SwiftUI dependency. The wire security boundary and
future TLS work are documented in `PROTOCOL.md`. `AudioLinkMobile` currently
composes Core/DSP/Networking with an iOS-only AVAudioSession/AVAudioEngine
adapter and a small controller-driven SwiftUI state machine. The additional
lab packages have shared models but are not wired into the mobile executable.
The Mac remains the final correlation authority for recordings received from
an iPhone; schedule and network clock observations are diagnostics, never
acoustic delay.

`AudioLinkReporting` is a separate presentation/export boundary. It maps
sanitized `MeasurementHistorySession` and run values into a stable
`ReportDocument` (schema 1.0), rather than encoding database rows directly.
Its renderers are Foundation-only for JSON/CSV/HTML and use native macOS
Core Graphics/PDFKit for PDF/PNG. It never receives source URLs or bookmarks by
default. Report writing is asynchronous and cancellation-aware; CSV uses a
directory of explicitly named tables so run-level data, session summaries, and
drift observations cannot be confused.

`AudioLinkPlatform` is the v2 internal execution boundary. Modules declare
capabilities and configuration schemas through `MeasurementModuleDescriptor`;
results use a common provenance/quality/uncertainty/artifact envelope without
forcing every module to expose a delay field. `MeasurementJobQueue` owns FIFO
execution and conservative resource locking. `AudioLinkAutomation` is the
headless adapter; hardware/plugin/path commands remain explicit availability
boundaries. `AudioLinkBundle` is independent of SQLite and stores a staged
manifest plus checksums; raw audio is opt-in and validation never executes
bundle HTML or scripts.

## Units and time

Sample offsets are the canonical representation of measured delay. Conversion
to seconds or milliseconds requires an explicit `SampleRate`. Wall-clock event
times use `Date`; real-time engine diagnostics also retain Core Audio host time
and audio sample time. Those scheduling observations are never substituted for
the correlation-derived end-to-end delay.

## Concurrency

Shared values conform to `Sendable`. Mutable stores are actors. The macOS model
is `@MainActor` isolated and receives dependencies at the composition root.
`NewMeasurementViewModel` owns one generation-tagged operation task: a new file
selection cancels superseded work, changing input or configuration clears stale
results, and a second Analyze action cannot start while analysis is active.
The live feature service delegates decoding and preprocessing to their detached
DSP workers; correlation likewise runs on its detached user-initiated worker.
Only state publication and clipboard presentation remain on the main actor.
SQLite access is serialized by its repository actor; WAL, foreign keys and a
busy timeout protect concurrent application reads and writes. File analysis
publishes its result before awaiting history persistence, so a storage failure
cannot turn a valid DSP result into an analysis failure.
The input tap never touches SwiftUI, storage, or DSP. Capture memory is sized
from pre-roll + signal + post-roll before the engine starts; the tap performs a
bounded copy into that storage plus discontinuity/overflow counters. Final PCM
materialization, preprocessing, FFT correlation, quality assessment, and SQLite
writes happen only after the tap is removed.

## Error boundary

`MeasurementError` carries a concise user-facing description and structured
debug context without attempting to encode arbitrary `Error` values. This
makes failures safe to persist, transfer, and render in UI while retaining the
underlying error type and diagnostic message.

## Version and release boundaries

`AudioLinkReleaseMetadata` supplies the app/build and algorithm defaults. The
protocol, report, database, bundle, module, and automation contracts each
carry an independent schema/version constant; they are not one shared version
number. SQLite performs additive migrations and refuses a newer schema; report
and bundle JSON use their own versioned contracts and are not raw database
dumps. The CLI is built from the same package graph as the app, while the
optional automation server is explicit, token-protected, and loopback-only.
Release scripts run clean package tests/builds, optional Python validation, and
an unsigned/ad-hoc artifact plus SHA-256 manifest.
Signing, provisioning, notarization, and physical audio/mobile validation
remain outside this repository's credentials.
