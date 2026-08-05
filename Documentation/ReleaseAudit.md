# v1.0 release audit

This document records the evidence available for the release candidate. It is
deliberately a checklist, not a claim that unavailable hardware has been tested.

## Findings and actions

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
| Privacy | History/report builders omit absolute paths/bookmarks/audio by default | Verified by report/storage tests and `PRIVACY.md` |
| Network security | Pairing, token, replay, size, and checksum guards exist; TCP is not encrypted | Explicit release blocker for hostile-LAN use; do not claim TLS |
| Long input memory | 60 s full benchmark reached ~1.16 GiB peak RSS during FFT correlation | Known v1 limit; multi-minute support requires streaming/coarse-to-fine work |
| Versioning | Release metadata is centralized; SQLite and report schemas are independently versioned | App bundle script now accepts version/build overrides |
| Signing | Local bundle is ad-hoc/unsigned | Developer ID, provisioning, archive, notarization are not verified here |
| Release flow | `Scripts/release.sh --skip-validation` generated a versioned ZIP, SHA-256 file, and manifest; checksum verified | Validation was intentionally skipped on this host because NumPy/SciPy are absent |

## Required manual checks before calling the v1.0 package production-ready

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
