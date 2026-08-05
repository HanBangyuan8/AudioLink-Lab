# AudioLink Lab platform and labs

This reference consolidates Core Audio, realtime, networking, mobile, device, interface, plugin, signal-path, distributed, and performance documentation.


---

<!-- Consolidated topic section. -->

## Architecture

AudioLink Lab uses a package-first architecture so measurement code is shared
by macOS and the native iOS companion without importing SwiftUI.

### Dependency direction

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
future TLS work are documented in the Security and Data reference.
`AudioLinkMobile` currently
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

### Units and time

Sample offsets are the canonical representation of measured delay. Conversion
to seconds or milliseconds requires an explicit `SampleRate`. Wall-clock event
times use `Date`; real-time engine diagnostics also retain Core Audio host time
and audio sample time. Those scheduling observations are never substituted for
the correlation-derived end-to-end delay.

### Concurrency

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

### Error boundary

`MeasurementError` carries a concise user-facing description and structured
debug context without attempting to encode arbitrary `Error` values. This
makes failures safe to persist, transfer, and render in UI while retaining the
underlying error type and diagnostic message.

### Version and release boundaries

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


---

<!-- Consolidated topic section. -->

## Core Audio Device Profiler

`AudioLinkRealtime` exposes `AudioPropertyProvider`, `AudioDeviceProfiler`, and `AudioDeviceSnapshot`. The provider is the only layer that constructs native `AudioObjectPropertyAddress` values; snapshot and UI layers use typed, scope-aware values.

The macOS provider reads device identity, transport, clock domain, alive/running state, stream configuration, nominal and advertised sample rates, buffer size/range, safety offset, and global/input/output latency. Missing properties are capability gaps, not fatal errors. OSStatus failures retain the operation and property address in `AudioDevicePropertyError`.

Selectors currently mapped: `kAudioHardwarePropertyDevices`, `kAudioObjectPropertyName`, `kAudioObjectPropertyManufacturer`, `kAudioDevicePropertyDeviceUID`, `kAudioDevicePropertyModelUID`, `kAudioDevicePropertyTransportType`, `kAudioDevicePropertyClockDomain`, `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyDeviceIsRunning`, `kAudioDevicePropertyNominalSampleRate`, `kAudioDevicePropertyAvailableNominalSampleRates`, `kAudioDevicePropertyBufferFrameSize`, `kAudioDevicePropertyBufferFrameSizeRange`, `kAudioDevicePropertySafetyOffset`, `kAudioDevicePropertyLatency`, `kAudioDevicePropertyStreamConfiguration`, `kAudioDevicePropertyHogMode`, volume/mute, data-source, and clock-source capability selectors.

Snapshots distinguish advertised capabilities from verification (`verified` remains `nil` until an explicit safe format/engine check). Snapshot JSON can be stored in SQLite schema v5 through `DeviceSnapshotRecord`; callers choose anonymisation before export.

Change monitoring is actor-owned and coalesces snapshot changes. Core Audio listener blocks are owned by the provider and removed/replaced by address; callbacks only schedule work. The bounded polling fallback avoids property reads on a HAL callback.

Manual hardware checklist: built-in speaker, built-in microphone, USB class-compliant interface, Bluetooth headset, BlackHole/Loopback virtual device, Aggregate Device, and Multi-Output Device. Automated tests use a mock provider and do not constitute hardware verification.

Known limits: control elements (volume/mute/data source), aggregate sub-device drift compensation, stream physical format ranges, hog mode ownership, and independent-clock claims are modelled but not populated by the first provider pass.


---

<!-- Consolidated topic section. -->

## Audio Interface Benchmark Lab

`BenchmarkPlan`, `BenchmarkMatrixBuilder`, `BenchmarkRunner`, and the result models separate:

* reported Core Audio input/output, safety-offset and stream latency;
* theoretical `2 × buffer + input + output + safety + stream` frames;
* correlation-measured latency;
* unexplained measured-minus-theoretical frames.

Only advertised sample-rate and buffer combinations are generated. `AudioDeviceConfigurationTransaction` captures, applies, waits for stability, confirms, and restores settings on normal and cancellation paths. The runner does not write SQLite or update UI from an audio callback.

Physical loopback, Bluetooth, aggregate, and virtual-driver behaviour require manual testing. The application does not change the default route without an explicit user action and makes no electrical safety claims about cabling.


---

<!-- Consolidated topic section. -->

## Audio Unit Plugin Profiler

`AudioLinkPlugin` defines a helper-process boundary (`AudioUnitHelperRequest`/`Response`), a timeout, sanitisation of NaN/infinite output, and typed reported-versus-measured results. Deterministic mock runners cover pass-through, fixed delay, gain, polarity inversion, low-pass, distortion, noise, tail, NaN, crash and hang behaviours.

The first production slice intentionally does not load arbitrary third-party components in the app process. A real AUv2/AUv3 scan/render helper and signed XPC entitlement setup remain deployment work. Validation status is never inferred from a mock result, and VST3 is not claimed. Repeatedly crashing or timing-out plugins stay in safe mode until the user explicitly retries them.


---

<!-- Consolidated topic section. -->

## Signal Path Measurement Mode

`AudioLinkSignalPath` stores an explicit graph of devices, applications, plugin chains and physical processors. External DAW nodes can be described manually; the app does not pretend to inspect every DAW bus or plugin chain.

Four modes are represented: continuous capture, scheduled window, repeated marker, and offline file round-trip. Deterministic start/calibration/main/timing/end markers carry a session UUID and marker version as machine-readable metadata; they are not an inaudible watermark. Marker detection reports missing start/end, incomplete capture, version mismatch and correlation confidence so callers can warn rather than make a causal claim. `PathComparison` keeps sample-rate differences explicit.

Generic templates can describe Logic Pro, Ableton Live, Reaper, OBS, BlackHole and physical inserts, but no software-version behaviour is hard-coded. Manual validation remains required for DAW delay compensation, live monitoring, offline bounce alignment and virtual-device resampling.


---

<!-- Consolidated topic section. -->

## Distributed Measurement Network

`AudioLinkDistributed` adds a coordinator-owned star topology for simulated
and future multi-node sessions. Nodes advertise capabilities, receive explicit
assignments, and advance through invited → ready → armed → running → uploading
→ analyzing → completed. The coordinator refuses to arm until every required
node is ready and rejects messages carrying another session ID.

Clock synchronization uses the existing four-timestamp ping-pong observation.
RTT, offset, drift, observation age, scheduling, callback, and network
asymmetry are retained separately. `UncertaintyBudget` combines declared
components by root-sum-square; the final acoustic arrival is never replaced by
a network timestamp. Failure policy is explicit (fail all, continue, retry,
skip, or wait for reconnect), and missing nodes are listed in results.

This release does not claim a hard real-device node-count limit, sub-sample
cross-device synchronization, arbitrary mesh routing, or automatic spatial
acoustic alignment. Bonjour/Network security limits remain those in the
Security and Data reference; real multi-device validation is a manual
checklist item.


---

<!-- Consolidated topic section. -->

## Multi-device networking foundation

`AudioLinkNetworking` is the first multi-device layer. It is a Foundation-only
package (no SwiftUI, DSP, or app target dependency) and can be reused by a
future iOS companion.

### Components

- `PeerDiscoveryService` and `BonjourPeerDiscoveryService` browse and advertise
  `_audiolink._tcp` using Network.framework. Discovery events are delivered via
  `AsyncStream` and listener/browser callbacks hop into an actor.
- `PeerConnectionProviding` exposes an async connection factory so the native
  iOS companion can connect to a discovered Mac without depending on SwiftUI.
- `PeerTransport`, `InMemoryPeerTransport`, `NetworkPeerTransport`, and
  `PeerConnection` provide framed, bounded, asynchronous transport. The memory
  transport is the deterministic test/simulation path.
- `SessionCoordinator` is an actor implementing hello, capability exchange,
  explicit short-code pairing, session configuration, prepare/ready/start/
  stop/cancel, progress/results, heartbeat, and clock messages.
- `TransferManager` streams a file in bounded chunks to a temporary file,
  verifies SHA-256, checks capacity and filename safety, then atomically moves
  it into place.
- `ClockObservation` records NTP-style `t1…t4` observations. It reports RTT and
  a clock-offset candidate only; it is not an absolute audio synchronization
  mechanism.

### Security boundary

Pairing is explicit: an unknown peer stays pending until the user compares and
confirms the six-digit code. After confirmation, the responder creates a random
session token. Every post-pairing envelope carries that token, a session ID, a
monotonic sequence, a UUID message ID, and a protocol version. `ReplayGuard`
rejects duplicate IDs and non-increasing sequence numbers. Message/file/chunk
limits and path-component checks apply before allocating or writing data.

The current `NetworkPeerTransport` uses TCP framing and **does not claim
encryption or authenticated transport**. Pairing protects accidental or
unapproved peers, not a hostile LAN or an actively spoofed endpoint. TLS with
identity pinning, key rotation, and a persisted trust decision are intentionally
reserved for a later protocol version. No security-scoped bookmark or source
audio is stored by this layer.

### Compatibility and state

The v1 envelope is JSON with sorted keys and ISO 8601 dates. Extra JSON fields
are ignored, so additive fields are forward-compatible. Unknown optional
messages are ignored; unknown critical messages are rejected safely. A version
mismatch, session mismatch, replay, malformed payload, heartbeat timeout, or
oversized transfer is a structured `ProtocolError` and never a crash.

The normal controller flow is:

```text
idle → connecting → awaitingPairing → paired → preparing → ready → running
                                                        ↘ stopping/cancelling
```

Disconnects transition to `reconnecting`; route/device changes must be handled
by the caller before resuming a measurement. A reconnect must retain the same
session token or begin a new explicit pairing. Heartbeat failure is surfaced as
an error rather than silently treating stale timestamps as audio delay.

See the wire-level field and message table in the security and data reference.

The iOS companion's controller/responder sequence, AVAudioSession limitations,
permission boundary, foreground requirement, and hardware checklist are in the
mobile section of the user guide.


---

<!-- Consolidated topic section. -->

## Performance baseline

The quick profile was run on this development host (macOS 15.7.8, Apple
Silicon arm64e, Swift 6) on 2026-08-05. Wall time is one invocation; RSS is the
process maximum and therefore grows cumulatively across rows.

| Operation | Input | Wall time |
| --- | ---: | ---: |
| Signal generation | 1 s | 17.1 ms |
| Signal generation | 10 s | 132.2 ms |
| FFT correlation | 1 s | 86.3 ms |
| FFT correlation | 10 s | 658.5 ms |
| Quality analysis | 1 s | 124.3 ms |
| Quality analysis | 10 s | 1,013.7 ms |
| Resampling | 1 s | 15.5 ms |
| Resampling | 10 s | 133.7 ms |
| Waveform min/max downsampling | 1 s | 7.8 ms |
| Waveform min/max downsampling | 10 s | 75.2 ms |
| Signal generation | 60 s | 797.9 ms |
| FFT correlation | 60 s | 4,619.7 ms |
| Quality analysis | 60 s | 6,753.8 ms |
| Resampling | 60 s | 784.2 ms |
| Waveform min/max downsampling | 60 s | 445.6 ms |
| SQLite bulk insert (100 sessions) | 100 records | 3.2 ms |
| HTML report | synthetic example | 0.5 ms |
| In-memory transport | 1 MiB | 0.02 ms |

The 60-second FFT run reached approximately 1.16 GiB maximum resident memory on
this host because the current implementation keeps full input/FFT working
sets. This is a release planning limit for longer recordings, not a promise
that arbitrary multi-minute files are safe. The 60-second profile is therefore
available for manual benchmark runs but is intentionally not part of every CI
run. These numbers are an engineering baseline, not a portable SLA. Regression review should compare
the same operation, input size, architecture, and toolchain with a generous
margin rather than failing on a single absolute threshold. Hardware audio
latency, Wi-Fi throughput, and iOS power/thermal behavior are not represented.

---

## Latency Graph UI baseline

AudioLink Lab's macOS interface is derived directly from the complete SwiftUI
source of `Latency Graph for ClashX Meta`. It is not a visual approximation.

The initial UI baseline copied these source files into `Apps/AudioLinkMac`:

- `LatencyGraphForClashXMetaApp.swift` (renamed to `AudioLinkLabApp.swift`)
- `Launcher.swift`
- `MotionSystem.swift`
- `VersionedNonlinearMotion.swift`
- `ChartDownsampler.swift`
- `RuntimeFeaturePlan.swift`
- `RuntimeOptimizationProfile.swift`
- the supporting chart, persistence, retention, and update files required for
  the copied application to compile

The copy checkpoint was verified by matching SHA-1 digests for all twelve
destination files. Three implementation-only compatibility changes were then
made for the Swift 6 build: the retained AppKit delegate is main-actor
isolated, the CSV formatter is created locally instead of shared as a
non-Sendable global object, and `NSSavePanel.allowedContentTypes` replaces the
deprecated file-type API. None of these changes affects layout, appearance,
animation, or interaction.

After the copy checkpoint, the Clash API client, release network client,
probe-batch executor, and copied SQLite/JSON persistence implementation were
removed. Their responsibilities now enter through `MeasurementPerforming` and
`MeasurementSessionStore`. The UI-facing projection was renamed from probe
and proxy terminology to measurement records and audio paths. These are domain
and dependency changes; the copied View hierarchy and motion implementation
remain the visual baseline.

The copied layout hierarchy, spacing, typography, material, color treatment,
hover states, press behavior, chart treatment, window behavior, modern/legacy
OS paths, and versioned motion system are the visual specification for
AudioLink Lab. Audio-domain work replaces models, labels, commands, data
sources, and chart values behind that specification.

Shared audio models and algorithms remain in independent packages. The
foundation measurement performer reports that live playback and capture are
unavailable instead of producing synthetic results. A later AVAudioEngine
implementation can replace it through dependency injection without changing
the copied UI.

The copied source was adapted only where required for the Swift 6 build and
AudioLink domain boundaries: the retained AppKit delegate is main-actor
isolated, CSV formatting is local rather than a shared non-Sendable global,
and the modern save-panel content type API is used. The copied View hierarchy
and motion implementation remain the visual baseline.

The semantic mapping is:

| Latency Graph surface | AudioLink Lab responsibility |
| --- | --- |
| Overview | New Measurement and live measurement summary |
| Proxy/node pages | Audio devices and measurement channels |
| Recent probe records | Measurement run history |
| Latency charts | Delay, jitter, drift, and confidence plots |
| Probe controls | Playback/capture measurement controls |
| Settings panel | Audio formats, devices, appearance, and measurement defaults |
| Menu bar panel | Current measurement status and recent result |
