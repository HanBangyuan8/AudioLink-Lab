# WAV-to-WAV New Measurement workflow

The macOS New Measurement feature is the first end-user composition of the
package APIs. It deliberately contains no audio capture, networking, or copied
DSP implementation.

## Layers

```text
NewMeasurementView
        │ user intents and bindings
        ▼
NewMeasurementViewModel (@MainActor)
        │ NewMeasurementServicing
        ▼
LiveNewMeasurementService
        ├── AudioFileImporter
        ├── AudioPreprocessor
        └── MeasurementQualityAnalyzer
                └── DelayAnalysisEngine / CorrelationEngine
```

The ViewModel uses a monotonically increasing operation generation. Replacing a
file, changing configuration, or cancelling increments the generation and
cancels the prior task. A late response may therefore never publish a stale
result. `analyze()` ignores a second request while `importing` or `analyzing`.

## State transitions

```text
idle ── import ──> importing ── one file ──> idle
                                  two files ──> ready
ready ── analyze ──> analyzing ── success ──> completed
                         ├── error ──> failed
                         └── cancel ─> cancelled

file/configuration change from completed clears the result immediately
```

The imported files remain in canonical planar Float32 memory. Security-scoped
file access is held only while decoding; analysis does not need permanent file
permission or a bookmark.

## Default policy

- channel 1 from each file, while preserving aligned stereo for independent
  channel-quality diagnostics;
- no downmix and automatic polarity detection;
- `0...2000 ms` search range;
- DC removal enabled, normalization and high-pass disabled;
- resample the recording to the reference rate when needed;
- automatic direct/FFT selection, 50% minimum overlap, and subsample
  interpolation enabled.

Every transformation is visible in configuration and is recorded in the
preprocessing log. A user can select “Require matching sample rates” to forbid
resampling.

## Result and errors

`NewMeasurementAnalysis` retains prepared inputs, the full
`QualityAssessedMeasurement`, and a UI-neutral result presentation. Invalid
quality may show warnings and recommendations while leaving delay fields
unavailable. Copy Result emits stable key/value text rather than a screenshot or
localized prose-only value.

`NewMeasurementFailure` maps importer, preprocessor, correlation, cancellation,
permission, and resource failures to a stable code, title, explanation,
recovery suggestion, and optional technical context. Raw `NSError` text is not
the only user-visible description.

## Verification

App tests use a mock service for state-machine behavior and one runtime-generated
PCM32 WAV fixture for the complete importer → preprocessor → direct correlation
→ quality path. The fixture contains a deterministic 80-sample delay.
