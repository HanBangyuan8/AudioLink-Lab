# Reliability, concurrency and security red-team review

Date: 2026-08-05  
Scope: Prompt 28 review of the current AudioLink Lab workspace.

## Executive conclusion

The offline file-analysis and simulated measurement foundations are suitable
for continued development and ordinary user recordings under the documented
limits. They are **not v2.0 release-ready** for the full feature set. The
remaining release blockers are real third-party Audio Unit process isolation,
full Core Audio configuration restoration under process/device failure, and
unverified real-hardware/iOS/LAN stress coverage. The current LAN protocol is
not suitable for an untrusted network because it has no TLS or authenticated
peer identity; use pairing only on a trusted LAN.

## Real architecture and trust boundaries

```text
SwiftUI macOS/iOS
  -> feature state/view models
  -> AudioLinkCore value models and errors
  -> DSP (import/preprocess/signal/correlation/quality)
  -> Realtime (AVAudioEngine/Core Audio/benchmark)
  -> Storage (actor-owned SQLite + migrations)
  -> Reporting/Bundle (versioned export DTOs)
  -> Networking/Automation (bounded protocol and localhost router)
```

The package boundary script (`Scripts/check-architecture.sh`) verifies that
Core/DSP/Networking/Storage/CLI do not import SwiftUI or app targets and that
report models do not import storage. GUI and CLI file analysis both call
`HeadlessFileAnalyzer`/`CorrelationEngine`, rather than duplicating DSP.

## Adversarial findings

| Severity | Finding | Status / trigger |
| --- | --- | --- |
| Critical | Third-party Audio Units are not actually helper-process isolated. A hanging/crashing plugin can affect the host. | **Unfixed blocker.** `AudioUnitProfiler` still uses an injected in-process runner. |
| Critical | LAN transport has no TLS/authenticated peer identity. | **Documented blocker.** Pairing is user-confirmed but does not protect a hostile LAN from active interception. |
| High | Audio callback previously used `NSLock` and a growable Swift array. | **Fixed.** Replaced with `AudioLinkRealtimeSupport` bounded C11-atomic single-producer storage. |
| High | In-memory/network receive cancellation could leave a continuation waiting forever. | **Partly fixed.** In-memory waiter removal and Network.framework continuation gates now cancel/close safely. Real-device disconnect timing remains unverified. |
| High | Protocol accepted stale run control messages with weak run/state validation. | **Fixed.** Active run IDs, allowed-state checks, numeric validation and token bounds were added. |
| High | A replay-ID window was cleared all at once, making recent identity history unnecessarily weak. | **Fixed.** Eviction is now oldest-first; sequence monotonicity remains the primary check. |
| High | Importers could allocate based on a maliciously large declared frame count. | **Fixed.** Configurable decoded-frame/byte limits reject before allocation. |
| High | Bundle checksums and manifests were read as one unbounded `Data`. | **Fixed.** Checksums stream; manifests have a 4 MiB cap; resolved traversal/case collisions are checked. |
| High | Migration changed an existing DB without a pre-migration recovery copy. | **Fixed.** WAL is checkpointed and a non-overwritten `*.pre-migration-vN` sidecar is created before migration. |
| Medium | HTTP automation previously assumed one read contained the entire request. | **Fixed.** Bounded header/body framing, 15-second deadline and 8-connection cap were added. Full slow-client/network integration remains unverified. |
| Medium | Error diagnostics included absolute importer/exporter paths. | **Fixed.** Errors retain file name only; generated artifact scanner added. |
| Medium | Core Audio/AVAudioEngine restoration after a process kill or physical unplug is not journaled. | **Unfixed.** Manual recovery checklist required. |
| Medium | Some platform boundary classes remain `@unchecked Sendable`. | **Reviewed/limited.** They are lock/actor/pointer wrappers, but they need platform stress validation; no blanket annotation was added. |

### `@unchecked Sendable` inventory

Every production annotation was inspected rather than added as a compiler
escape hatch:

| Symbol | Boundary invariant | Remaining verification |
| --- | --- | --- |
| `MobileAudioSessionManager` | `@MainActor` owns all AVAudioSession/engine state; callbacks hop to that actor. | Physical iOS interruption/route tests. |
| `MobileCaptureAccumulator`, `RecordingAccumulator` | Native accumulator is preallocated and single-producer; snapshot occurs after tap removal/stop. | Device callback teardown under unplug/process termination. |
| `SQLiteConnection` | Pointer is only touched by the repository actor. | Multi-process SQLite stress. |
| `LocalAutomationServer`, `ConnectionLease`, `AutomationRequestDeadline` | Dispatch queue/lock gates connection count and deadline; no mutable request state crosses unchecked. | Real slow-client/flood campaign. |
| `CLIInterruptController`, view-model relays | Lock-protected or main-actor handoff of immutable snapshots. | App termination while callback is pending. |
| `FFTSetupCache` | `NSLock` guards the bounded setup cache; cached transform objects are immutable after creation. | Long-running contention benchmark. |
| `NetworkPeerTransport`, `NetworkContinuationGate` | NWConnection callbacks complete a lock-gated continuation exactly once; connection reference is immutable. | Real route changes and hostile socket peers. |
| `ConverterInputProvider`, `SystemCoreAudioPropertyProvider`, `PlaybackCompletionGate` | Framework callback/lock or actor boundary owns the pointer/continuation lifecycle. | Hardware callback teardown and OS-version matrix. |

No annotation is used to make a mutable domain model or database record
implicitly safe.

## Realtime-thread review

The macOS and iOS capture accumulators now share a preallocated C buffer. The
tap path validates channel/pointer/frame count, performs bounded `memcpy` and
atomic counters only. Snapshot/copy/metrics occur after tap removal and stop.
The callback contains no allocation, lock, actor hop, log, JSON, file, DB,
network or FFT operation. Overflow and dropped-buffer counters are retained in
diagnostics. The C regression test covers bounded writes, stop behavior and
overflow without growth.

`PlaybackCompletionGate` is used off the realtime callback and is not a
replacement for callback-safe storage.

## Concurrency and cleanup

Actor-owned session, repository, transfer and job state passed package tests.
Cancellation now propagates through in-memory waiters, Network.framework send/
receive gates, importer/preprocessor workers and the realtime engine cleanup
path. The remaining risk is unstructured platform callback lifetime under real
route interruption and process termination; those require hardware runs.

## File, bundle and database red-team coverage

Automated coverage includes empty/truncated/NaN WAV fixtures, frame/byte limits,
path and symlink checks, manifest schema/duplicate/checksum failures, temporary
transfer cleanup, checksum mismatch, transaction rollback, corrupt DB
preservation, old-schema migration and migration backup assertions. ZIP archive
extraction is not implemented by the current directory-bundle API; an archive
reader must not be added without an isolated expansion quota.

## Network red-team coverage

Automated coverage includes unknown critical versions, malformed/oversized
messages, pairing, replay, stale sequence, cancelled receive, checksum and
interrupted transfer. Connection count, request size, body framing and timeout
are bounded. Not yet verified: active MITM, TLS identity, connection-flood
behavior on a real socket, network switching and 10-node reconnect storms.

## Plugin red-team coverage

Mock runner tests cover failure/timeout/result sanitization at the abstraction
level. They do **not** prove that a real AUv2/AUv3 plugin crash is isolated: the
current implementation does not launch a helper process. Do not load unknown
third-party plugins in a production session.

## Pressure and fault results

- Full `Scripts/test-packages.sh` matrix: 227 tests passed across the 15
  package/host targets (the individual security-relevant counts below are
  included in that total).
- `AudioLinkRealtime`: 43 tests passed, including the new bounded-capture test.
- `AudioLinkNetworking`: 11 tests passed, including cancelled receive cleanup.
- `AudioLinkStorage`: 20 tests passed, including migration backup assertions.
- `AudioLinkBundle`: 4 tests passed after streaming/path hardening.
- `AudioLinkAutomation`: 6 tests passed after bounded HTTP framing changes.
- `AudioLinkDSP`: 96 tests passed after decoded-size-limit and path-redaction
  changes (including the absolute-path diagnostic regression test).
- iOS package tests: 6 passed on the macOS fallback build; physical iOS route,
  interruption and background behavior are unverified.
- macOS feature/app tests: 22 passed.
- Privacy scanner passed `Examples/SyntheticReport.json` and the anonymous
  example bundle. `python3 -m py_compile` passed.
- No hardware, sleep/wake, disk-full, process-kill, active MITM or real plugin
  crash test was possible in this environment.
- The requested 1,000-file/100-real-time/100-network-disconnect pressure
  campaigns were not run here; package-level bounded/cancellation tests are
  regression coverage, not a substitute for those campaigns.

## Release decision

**Not release-ready for v2.0.** Offline file analysis may be used with ordinary
user recordings, subject to size/privacy limits. Do not claim safety for
untrusted LAN peers, third-party plugins, or unattended device configuration
benchmarks until the Critical/High blockers above are closed and the manual
checklist is executed.

Next priority: implement a separate signed/limited plugin helper with hard
timeouts and quarantine; add a device-configuration restoration journal; then
run hardware and LAN fault campaigns before changing the release status.
