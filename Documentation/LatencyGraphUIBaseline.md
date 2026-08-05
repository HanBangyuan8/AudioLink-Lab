# Latency Graph UI baseline

AudioLink Lab's macOS interface is derived directly from the complete SwiftUI
source of `Latency Graph for ClashX Meta`. It is not a visual approximation.

The following source files were copied into `Apps/AudioLinkMac` as the initial
UI baseline:

- `LatencyGraphForClashXMetaApp.swift` (renamed to `AudioLinkLabApp.swift`
  after the copy checkpoint)
- `Launcher.swift`
- `MotionSystem.swift`
- `VersionedNonlinearMotion.swift`
- `ChartDownsampler.swift`
- `RuntimeFeaturePlan.swift`
- `RuntimeOptimizationProfile.swift`
- the supporting chart, persistence, retention, and update files required for
  the copied application to compile at the copy checkpoint

At the copy checkpoint, all twelve destination files had the same SHA-1 digest
as their source counterparts. Three implementation-only compatibility changes
were then made for the Swift 6 build:

1. the retained AppKit delegate is isolated to `MainActor`;
2. the CSV formatter is created locally instead of being shared as a
   non-Sendable global object;
3. `NSSavePanel.allowedContentTypes` replaces the deprecated file-type API.

None of these changes affects layout, appearance, animation, or interaction.

After the copy checkpoint, the Clash API client, release network client,
probe-batch executor, and copied SQLite/JSON persistence implementation were
removed. Their responsibilities now enter through `MeasurementPerforming` and
`MeasurementSessionStore`. The UI-facing projection was renamed from probe and
proxy terminology to measurement records and audio paths. These are domain and
dependency changes; the copied View hierarchy and motion implementation remain
the visual baseline.

## Migration rule

The copied layout hierarchy, spacing, typography, material, color treatment,
hover states, press behavior, chart treatment, window behavior, modern/legacy
OS paths, and versioned motion system are the visual specification for
AudioLink Lab.

Audio-domain work should replace models, labels, commands, data sources, and
chart values behind that specification. It must not redesign the interface as
a generic sidebar application. Intentional visual changes require an explicit
design decision and before/after UI comparison.

## Planned semantic mapping

| Latency Graph surface | AudioLink Lab responsibility |
| --- | --- |
| Overview | New Measurement and live measurement summary |
| Proxy/node pages | Audio devices and measurement channels |
| Recent probe records | Measurement run history |
| Latency charts | Delay, jitter, drift, and confidence plots |
| Probe controls | Playback/capture measurement controls |
| Settings panel | Audio formats, devices, appearance, and measurement defaults |
| Menu bar panel | Current measurement status and recent result |

Shared audio models and algorithms remain in the independent packages. The
foundation measurement performer intentionally reports that live playback and
capture are unavailable instead of producing synthetic results. A later
AVAudioEngine implementation can replace it through dependency injection
without changing the copied UI.
