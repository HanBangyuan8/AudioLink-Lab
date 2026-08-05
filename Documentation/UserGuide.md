# AudioLink Lab user guide

This guide consolidates installation, first-use, measurement workflows, history, reports, troubleshooting, and platform limitations.


---

<!-- Consolidated topic section. -->

## Installation and build

Requirements: macOS 13 or newer, Xcode 16 or newer, Swift 6, and an Apple
Silicon or Intel Mac. The iOS companion requires an iOS 16 SDK and a signing
team for device installation.

### Development build

```bash
./Scripts/test-packages.sh
./Scripts/build-all.sh
./Scripts/package-app.sh development
open "dist/AudioLink-Lab-v1.0.0-macOS-universal.app"
```

The app bundle is ad-hoc/unsigned for local development. It is not notarized
and may require the user to approve it in Privacy & Security. A distribution
build must be produced by a developer with a Developer ID certificate,
entitlements, provisioning profiles, archive/export settings, and notarization
credentials. The repository deliberately does not fake those credentials.

### Validation and benchmarks

The optional Python validation environment is separate from runtime:

```bash
python3 -m venv .venv-validation
. .venv-validation/bin/activate
python3 -m pip install -r Validation/requirements.txt
python3 Validation/run_validation.py --profile quick
./Scripts/run-benchmarks.sh quick
```

The current host may not have NumPy/SciPy installed; in that case validation is
reported as unverified rather than silently skipped.

On this host, the direct SwiftPM iPhoneOS/Simulator cross-build prints the
toolchain warning `using sysroot for 'MacOSX' but targeting 'iPhone'` while
linking. Swift source compilation with `-warnings-as-errors` succeeds; this is
an Xcode/SwiftPM cross-SDK diagnostic, not a project Swift warning. A production
Xcode project/archive should be used to eliminate or review that toolchain
warning before distribution.


---

<!-- Consolidated topic section. -->

## First-use guide

For a file measurement, open **New Measurement**, choose a reference WAV and a
recording WAV, leave the conservative defaults in **Configure**, and press
**Analyze**. The result is a correlation-derived delay in samples and
milliseconds plus quality level, peak, polarity, warnings, and processing log.
Changing either file or a relevant option invalidates the old result.

For a same-Mac real-time run, choose the output and input devices, lower the
volume, confirm the feedback warning, grant microphone access when prompted,
then start. Capture begins before playback; software scheduling timestamps are
diagnostics only. Stop or cancel at any time.

History is local SQLite and results-only by default. Reports are privacy-filtered
unless detailed identifiers are explicitly enabled. The iOS companion requires
the app in the foreground, microphone and Local Network permission, explicit
pairing, and a trusted LAN; network timestamps schedule a capture window but do
not replace acoustic correlation.


---

<!-- Consolidated topic section. -->

## WAV-to-WAV New Measurement workflow

The macOS New Measurement feature is the first end-user composition of the
package APIs. It deliberately contains no audio capture, networking, or copied
DSP implementation.

### Layers

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

### State transitions

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

### Default policy

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

### Result and errors

`NewMeasurementAnalysis` retains prepared inputs, the full
`QualityAssessedMeasurement`, and a UI-neutral result presentation. Invalid
quality may show warnings and recommendations while leaving delay fields
unavailable. Copy Result emits stable key/value text rather than a screenshot or
localized prose-only value.

`NewMeasurementFailure` maps importer, preprocessor, correlation, cancellation,
permission, and resource failures to a stable code, title, explanation,
recovery suggestion, and optional technical context. Raw `NSError` text is not
the only user-visible description.

### Verification

App tests use a mock service for state-machine behavior and one runtime-generated
PCM32 WAV fixture for the complete importer → preprocessor → direct correlation
→ quality path. The fixture contains a deterministic 80-sample delay.


---

<!-- Consolidated topic section. -->

## Real-time Measurement

The first real-time mode measures a same-Mac path by playing a deterministic
test signal through one Core Audio output, recording one Core Audio input, and
running the existing offline correlation and quality engines on the capture.
It supports acoustic speaker-to-microphone paths, hardware interface loopback,
and virtual-device chains without routing the captured input back to the output.

### Package boundary

`AudioLinkRealtime` is a Swift Package with macOS and iOS deployment declarations.
The current explicit device implementation is macOS-specific; its public models,
permission contract, playback/recording contracts, state machine, result, and
mockable orchestration are UI-independent and reusable by a future companion.

The package exposes:

- `AudioDeviceService` and `SystemAudioDeviceService`;
- `MicrophonePermissionAuthorizing` and its AVFoundation implementation;
- `PlaybackController` and `RecordingController`;
- `AVAudioEngineRealtimeController`;
- `AudioRouteConfiguration`, `RealtimeMeasurementConfiguration`,
  `RealtimeMeasurementState`, and `AudioEngineDiagnostics`;
- `RealtimeMeasurementEngine` and `RealtimeMeasurementSaving`.

The package also composes this single-run engine into repeated plans. See the
repeated-measurement section above for pause/resume semantics, statistics,
outlier rules, visualization, and persistence behavior.

The application injects a results-only SQLite saver. No absolute device-related
path or captured PCM is stored. Complete engine diagnostics are encoded into the
run processing log alongside the normal preprocessing operations.

### Sequence and timing truth

The state machine is:

```text
validate route → request permission if needed → generate signal → prepare output
→ start input tap and engine → pre-roll → schedule/play → post-roll
→ remove tap/stop → explicit preprocessing → cross-correlation + quality → save
```

The recording engine is running before pre-roll begins and before playback is
scheduled. `recordingBeganBeforePlayback` is derived from monotonic host-time
ordering and is reported as a pipeline invariant. The engine also records:

- engine and recording host/sample times;
- playback schedule and data-played-back completion host times;
- first and last recorded sample times;
- requested buffer size and number of captured buffers;
- discontinuities, capture-storage overflow, and route changes;
- nominal sample rate and selected device UIDs.

These values diagnose setup and dropouts. They are not an acoustic latency
estimate. The public delay is the peak lag from the recorded PCM correlation,
including the existing fractional interpolation and explainable quality model.

### Route policy

Device enumeration uses Core Audio object properties for UID, display name,
manufacturer, transport, input/output channel counts, nominal rate, and system
default flags. During a measurement a lightweight Core Audio snapshot monitor
detects device removal and nominal-rate changes; either event on a selected
endpoint safely cancels the run.

This first version deliberately rejects different input/output nominal rates.
Automatic conversion would hide independent device clocks and could bias delay
or drift measurements. Users should choose endpoints with matching rates or
create/configure an Aggregate Device in Audio MIDI Setup. The signal is mono;
the physical output and input channels are selected independently.

### Real-time memory behavior

Before starting the engine, AudioLink preallocates capture storage for pre-roll,
the full generated signal, post-roll, and eight additional I/O buffers. The tap
does not append Swift arrays, lock shared UI state, run DSP, write files, or
allocate per buffer. It copies the selected Float32 channel into bounded storage
and updates counters. Exceeding that capacity increments `overflowCount` and
truncates only the excess frames; quality and diagnostics then make the run
inspectable rather than crashing.

### Safety and permissions

The microphone prompt is not shown at launch or during signal preview. It is
requested only after the user starts a real-time measurement. A denied result
includes the System Settings recovery path.

The default logarithmic sweep uses about 18% normalized amplitude (roughly
−15 dBFS), 80 Hz to the lower of 18 kHz or 45% of sample rate, and short raised
cosine fades. The UI requires explicit volume and feedback acknowledgements.
AudioLink does not connect the input node to the mixer, but users must still
avoid feedback in external interfaces, virtual routers, and acoustic paths.

### Automated validation

The no-hardware suite uses protocol mocks and a deterministic loopback that
copies the generated signal into a recording at a fixed sample offset. It covers:

- exact correlation delay and recording-before-playback ordering;
- success and SQLite-saver invocation;
- permission denied and request-on-demand;
- stop/cancel and duplicate-start rejection;
- input recording, output playback, and analysis failures;
- selected-device disconnect and nominal-rate change;
- preview without microphone permission;
- engine start count (one engine per measurement).

### Manual hardware validation still required

Automated tests cannot certify Core Audio driver or physical path behavior.
Before calling a release hardware-validated, test at minimum:

1. built-in speakers to built-in microphone at 44.1 and 48 kHz;
2. USB interface output-to-input loopback at 48 and 96 kHz;
3. separate compatible input/output endpoints and a configured Aggregate Device;
4. a virtual audio device without input monitoring;
5. unplugging each selected device during pre-roll, playback, and post-roll;
6. changing nominal rate in Audio MIDI Setup during a run;
7. microphone allow, deny, revoke, and re-enable flows in an ad-hoc signed app;
8. long repeated runs for buffer discontinuity, storage overflow, driver reset,
   and sleep/wake behavior;
9. Bluetooth routes separately—codec buffering and route renegotiation may be
   large and variable, so results need manual interpretation.

AVAudioEngine does not expose complete device underflow telemetry on every
driver. The current `underflowCount` remains zero unless a future lower-level
AudioUnit backend supplies it; captured sample-time discontinuities and bounded
storage overflow are measured today. Hardware I/O safety offsets, calibrated
latency compensation, independent-clock drift correction, and automatic
aggregate-device construction remain later work.


---

<!-- Consolidated topic section. -->

## Repeated measurements and statistics

Repeated real-time measurement freezes one `AudioRouteConfiguration` and one
signal/correlation configuration, executes warm-up plus measured runs, stores
every outcome in one history session, and calculates an inspectable aggregate.
It does not merge results recorded under a changed input, output, nominal sample
rate, channel, or buffer configuration.

### Public model and control boundary

`AudioLinkRealtime` exposes `MeasurementPlan`, `RandomSeedPolicy`, `RunOutcome`,
`RepeatedMeasurementReport`, `RunScheduler`, `RepeatedMeasurementController`,
`StatisticalAnalyzer`, and `OutlierDetector`. Its state is `preparing`,
`warmingUp`, `running`, `paused`, `cancelling`, `completed`, or `failed`.
Mockable runner, scheduler, device, and progress-saving protocols keep hardware,
timing, persistence, and UI out of the algorithm.

`AudioLinkCore` owns the Codable aggregate models so Storage can persist them
without importing the real-time package or SwiftUI. The app owns only state
projection, native Canvas rendering, and repository composition.

### Plan and state behavior

A plan accepts 1–1000 measured runs plus 0–100 warm-ups. The app offers quick
choices for 5, 20, and 100 runs. It also fixes interval, pre/post-roll, signal
kind, deterministic seed policy, whether warm-ups enter statistics, consecutive
failure policy, and outlier policy.

Before the plan and before every scheduled step, the controller revalidates the
frozen route. Pause stops the active single-run engine. Resume revalidates the
same route and retries an interrupted step rather than recording it as a failed
measurement. A route change aborts the plan; it never silently starts a new
population. Cancellation safely stops the engine and leaves already completed
runs stored and reviewable.

Progress reports scheduled/completed/success/failed/remaining step counts and
the latest valid delay. It intentionally does not invent a precise ETA because
permission, driver, capture, DSP, and storage time may differ between runs.

### Statistical definitions

All aggregate values are calculated from successful, non-discarded observations
in milliseconds. Failed runs remain in `outcomeCount` and `failureCount` but do
not enter the numeric delay population.

For selected delays `x[1...n]`:

- mean is `sum(x) / n`;
- variance is sample variance `sum((x - mean)^2) / (n - 1)`, in ms²;
- **jitter** is explicitly the sample standard deviation `sqrt(variance)`, in ms;
- peak-to-peak jitter is `max(x) - min(x)`;
- P50/P90/P95/P99 use Hyndman–Fan type 7 linear interpolation, matching NumPy/R;
- MAD is `median(abs(x - median(x)))` and IQR is `P75 - P25`;
- the mean confidence interval is a two-sided 95% Student-t interval
  `mean ± t(0.975,n-1) × s/sqrt(n)`.

The interval assumes independent observations from an approximately stationary
population. Audio runs can be autocorrelated, drifting, or multimodal, so it is
labeled with its method and is not a hardware guarantee.

Reliability labels are empirical communication guardrails: 0–4 selected samples
are `insufficient`, 5–19 `preliminary`, 20–49 `moderate`, and 50+ `strong`. An
interval is not emitted for fewer than two selected observations.

### Outliers

Two robust methods are implemented:

- scaled MAD: `abs(x - median) / (1.4826 × MAD) > threshold`, default 3.5;
- IQR fences: outside `[Q1 - k×IQR, Q3 + k×IQR]`, conventionally k=1.5.

Detection requires at least four successful observations. When robust scale is
zero, a differing value receives a finite maximum score so JSON remains valid.
Outliers retain run ID, index, value, method, threshold, score, and explanation.
They are never deleted. Users may switch between aggregates that include or
exclude marked observations; the raw run and failure lists do not change.

### Visualization and performance

The result UI uses SwiftUI `Canvas`, not per-sample Shapes or a chart dependency:
delay over index (warm-ups muted, failures crossed, outliers ringed), a bounded
histogram of at most 30 bins, a five-number box plot, and quality over index.
Render preparation caps a validated plan at 1000 points and Canvas draws one
node per plot. Statistics and orchestration run outside the main actor; only
immutable snapshots cross into the view model.

### Automated coverage and limits

Tests cover exact statistics and percentile edges, empty/single/equal samples,
multiple outliers, include/exclude, failure exclusion, quality distribution,
warm-up discard, repeated-failure stop, pause/resume retry, cancellation, route
change, persistence round-trip, v1→v2 migration, and plot-data bounds.

Real hardware still needs long-run testing for driver reset, temperature,
independent clocks, sleep/wake, acoustic movement, and feedback safety. The
aggregate reports observed correlation delay; it does not compensate for
undocumented hardware latency or claim successive runs are independent.


---

<!-- Consolidated topic section. -->

## Local measurement history

AudioLink Lab stores measurement history in a local SQLite database at
`Application Support/AudioLink Lab/History.sqlite`. SQLite is provided by the
Apple SDK and linked through the system `SQLite3` module. This avoids a network
dependency, keeps the storage boundary small, and gives the project direct
control over transactions, migrations, error mapping, and privacy-sensitive
columns.

The repository connection is owned by a Swift actor. SQLite is opened with
`FULLMUTEX`, foreign keys, a five-second busy timeout, and WAL journaling. Actor
isolation serializes application operations while WAL permits safe readers from
another process or repository connection.

### Schema v3

| Table | Purpose |
|---|---|
| `app_schema_version` | Explicit application schema version and migration timestamp. |
| `sessions` | Session identity, dates, name/notes, measurement/save types, app and algorithm versions, devices, legacy statistics, and optional repeated-run aggregate JSON. |
| `configurations` | Versioned opaque configuration payload plus searchable/comparable key-value summary. |
| `runs` | Run dates, quality, confidence, delay, sample rate, correlation/quality diagnostics, run statistics and notes. |
| `calibration_profiles` | Route-matched calibration profile blobs, fixed sample offset, method, confidence, date, notes and subtraction policy. |
| `files` | Role, random non-sensitive identifier, base file name, format and signal metrics, plus optional explicitly selected bookmark or relative managed-copy path. |
| `delay_estimates` | Canonical integer/fractional sample delay, sample rate, confidence and complete encoded estimate. |
| `quality_metrics` | One row per explainable metric, including normalized score, thresholds, weight and explanation. |
| `quality_issues` | Machine code, severity, user/technical explanations and recommended action. |
| `processing_steps` | Ordered, role-specific preprocessing operation and input/output frame counts. |
| `chart_cache_metadata` | Cache version, availability, signed correlation sequence metadata/blob, and waveform availability explanation. |

Foreign keys use `ON DELETE CASCADE`. Run date, quality and file-name indexes
support the History query path. Search text is parameter-bound and escapes SQL
`LIKE` wildcard characters.

Calibration profiles contain route descriptors but no raw audio or absolute file
paths. A run's `calibration_json` stores the profile ID and raw-versus-derived
result; the original delay row remains authoritative.

The correlation sequence is kept outside JSON as a versioned little-endian
Float32 blob. The associated first lag and sample count make the exact signed
sequence reconstructible for correlation and peak-detail plots without storing
raw audio. Quality, delay, diagnostics and configuration payloads use stable
Codable models.

### Privacy policy

The default policy is **results only**. It stores:

- base file names and random per-record file identifiers;
- audio format, frame count, duration, peak, RMS, clipping count and DC offset;
- explicit preprocessing configuration and log;
- delay, correlation, quality metrics/issues, diagnostics and statistics;
- creation time, app version and algorithm version;
- the signed correlation sequence required for correlation/peak inspection.

It does not store:

- absolute source paths or home-directory information;
- raw source or prepared audio;
- persistent file-access permission.

The repository rejects file names containing path separators, rejects absolute
or parent-relative managed paths, and rejects bookmarks/audio references on a
results-only record. JSON export inherits the same sanitized models.

The user can explicitly choose:

- **File access bookmarks**: saves security-scoped bookmarks, but no audio copy.
- **Audio copies**: copies both selected source files into the app container and
  stores only paths relative to that container. Deleting the run/session or
  clearing history deletes these managed copies; source files are untouched.
- **Do not save**: does not call the repository at all.

If copying succeeds but the database transaction fails, the persistence
coordinator removes the uncommitted copies. A history-save failure is presented
separately and never removes the completed analysis result from the UI.

### Sessions, runs and statistics

A session owns one frozen configuration and one or more runs. A normal file or
standalone real-time analysis creates one run. A repeated plan appends every
successful, failed, and warm-up step to the plan-ID session. Failed steps use an
explicit invalid-quality record without fake delay values.

`sessions.repeated_statistics_json` stores the selected aggregate and its
outlier method, threshold, marks, quality distribution, confidence interval,
and reliability label. Raw runs remain the authoritative source and marked
outliers are never deleted.

Statistics use the first valid run's sample rate as the canonical sample unit.
They include count, rounded mean/median/min/max delay, population standard
deviation expressed as seconds, and clock drift. Drift is the least-squares
slope of delay seconds against run time, multiplied by one million (ppm).

### Transactions and errors

Session replacement, bulk saving, multi-run append, multi-delete and clearing
use `BEGIN IMMEDIATE`, `COMMIT`, and `ROLLBACK`. Every child table is updated in
the same transaction. SQLite result codes map to structured
`MeasurementStorageError` values for open failure, corruption, migration,
constraint, encoding/decoding, transaction and query failures. Each error has a
short user-facing description and separate debug context.

The database is never automatically deleted or replaced when corruption is
detected. This preserves evidence for recovery and prevents a failed read from
silently destroying history.

### Migration design

SQLite `PRAGMA user_version` is the authoritative fast version check;
`app_schema_version` is the inspectable application record. Opening a new or
version-zero database creates schema v1, then applies additive v1→v2, v2→v3,
v3→v4 (device snapshots), and v4→v5 (opaque adaptive/spatial/distributed lab artifacts)
migrations in the same transaction. Existing v1 databases receive the nullable
`sessions.repeated_statistics_json` column. Version 3 adds nullable
`runs.calibration_json` and creates `calibration_profiles`; no table is rebuilt
or dropped. Both version markers move to 3 only after all alterations succeed.

Future migrations must be sequential and additive where practical:

1. read `user_version`;
2. reject a database newer than the running application;
3. begin one immediate transaction;
4. apply each missing migration in order without dropping user data;
5. update `app_schema_version` and `user_version` only after all steps succeed;
6. roll back every schema/data change on failure.

Tests verify that v0→v3 preserves a pre-existing legacy table, v1→v3 preserves
an existing session row, calibration profiles round-trip and delete safely,
repeated aggregates round-trip without changing raw runs, a forced child insert
failure rolls back the already inserted session, and corrupt input is reported
without changing its bytes.

### History and comparison UI

History sorts newest first and supports:

- file-name or note search;
- quality, device and measurement-type filters;
- bounded pagination;
- detail reopening and session name/note editing;
- individual and confirmed multi-run deletion;
- selected-run JSON export;
- confirmed clear-all;
- two-or-more-run comparison.

Comparison uses the first selected run as baseline and reports delay,
confidence, quality, configuration-key, sample-rate, preprocessing and device
differences. The models are independent from SwiftUI so a future chart-based
comparison can use the same data.

For a default results-only record, correlation and peak-detail data can be
reconstructed. The detail page explicitly states that waveforms cannot be
reconstructed because raw audio was not retained. With the explicit audio-copy
policy, managed sources remain available for a future asynchronous re-import
path; this phase reports that availability but does not silently decode them.

### Validation

Repository tests cover empty creation, schema tables, complete encoding/decoding,
second-connection reopening, update/delete, SQL transaction rollback, migration,
corruption, concurrent writes, 125-record pagination/filtering, privacy
validation, multi-run statistics and comparison. App tests cover automatic
results-only saving, do-not-save, independent save failure, security-scoped
bookmarks, managed audio copying/deletion, History search/update/filter,
comparison, export and multi-delete.


---

<!-- Consolidated topic section. -->

## Professional reports

`AudioLinkReporting` is the public export boundary for a run or session. The
schema is versioned independently from SQLite (`ReportSchemaVersion.v1`, wire
value `"1.0"`) and uses stable snake_case field names. Dates are ISO 8601 with
fractional seconds; every duration, delay, sample rate, drift and jitter field
has its unit in the field name or its CSV unit column.

### Privacy boundary

`ReportDocumentBuilder` copies only sanitized metadata. File names, format and
signal statistics are useful for reproducing an AV test, but absolute URLs,
home directories, security-scoped bookmarks, and raw audio are never placed in
a report. Device UID and file privacy identifiers are nullable and omitted by
default. `ReportPrivacyOptions(includeDetailedDiagnosticIdentifiers: true)` is
an explicit opt-in for support cases. The report model is not a database dump,
so future schema changes can preserve import compatibility.

### Formats

- JSON is the complete machine-readable `ReportDocument`; use
  `JSONCodec.decode` for a future report viewer.
- CSV writes `runs.csv` (one row per run), `session_summary.csv` when aggregate
  statistics exist, and `drift_observations.csv` when drift events exist.
  Values use an `en_US_POSIX` decimal point and RFC 4180-style escaping.
- HTML is self-contained, with inline CSS and SVG charts. Print styles remove
  dark-mode colors and avoid breaking a chart across pages.
- PDF is generated with PDFKit/Core Graphics, includes a project/date header,
  page numbers, wrapped diagnostic text and one page per chart.
- PNG exports the first selected chart at 1200×650 pixels. Use the existing
  result-page chart exporter for selecting a different chart.

All renderers check task cancellation and map file-system failures to
`ReportExportError`, so a caller can show a recoverable error instead of an
unexplained `NSError`. `Examples/SyntheticReport.json` is a small, non-personal
fixture suitable for documentation and Python ingestion examples.


---

<!-- Consolidated topic section. -->

## AudioLink Mobile companion

`Apps/AudioLinkMobile` is a native SwiftUI iOS companion. It reuses
`AudioLinkCore`, `AudioLinkDSP`, and `AudioLinkNetworking`; no shared algorithm
is copied into the app target. The mobile target is intentionally a small
companion surface, not a second copy of the macOS application.

### Roles and flow

The iPhone can advertise `controller`, `recorder`, and `player` roles. A
controller-driven run follows this sequence:

```text
Bonjour discovery → explicit code confirmation → capabilities
→ session configuration → prepare/ready → scheduled start
→ local AVAudioEngine capture/playback → stop → WAV transfer
→ final correlation on the Mac
```

The controller sends a deterministic signal plan (signal kind, rate, duration,
pre/post-roll, and a relative start delay). Each peer records its own host and
sample diagnostics. The relative network schedule only creates a safe capture
window; the acoustic delay is still obtained from the recording correlation on
the Mac. Network RTT and clock observations are never presented as acoustic
latency.

The current iOS workflow supports both directions in the shared controller:

- Mac/player → iPhone/recorder: the iPhone captures and streams a verified WAV
  back to the paired controller.
- iPhone/player → Mac/recorder: the iPhone schedules playback and receives the
  recorder's chunked WAV for the controller-side analysis path.

The final Mac-side UI orchestration and physical-device validation remain
follow-up work; the protocol, iOS state machine, deterministic loopback tests,
and file lifecycle are in place now.

### iOS audio behavior

`MobileAudioSessionManager` configures `AVAudioSession` according to the
negotiated role:

- `record` for recorder-only runs;
- `playback` for player-only runs;
- `playAndRecord` for controller/responder combinations.

The app requests microphone permission only when a run needs input. Local
Network and Bonjour declarations are in the app resources. The current route,
actual sample rate, input/output channel counts, buffer duration, Bluetooth
port presence, and speaker output are read back and shown in Diagnostics.
Preferred sample rate is a request, not a promise: iOS or an attached route
may negotiate a different value and the run is rejected if the signal cannot be
represented at the actual route rate.

Bluetooth HFP/A2DP and speaker routing are subject to iOS policy and hardware;
the app reports the route rather than claiming arbitrary input/output selection.
Route changes, interruptions (calls/Siri), and engine failures stop the run and
surface a recoverable error. The app does not enable `UIBackgroundModes`; keep
the phone in the foreground and unlocked for the current measurement flow.

### Recording retention and privacy

Recordings are written to an app-private temporary directory. By default the
responder transfers the WAV in bounded chunks, verifies its checksum, and
deletes the local copy after a successful transfer. The Settings screen lets a
developer retain the file until it is manually deleted. A future retention
policy can add a no-transfer diagnostic mode; the current controller does not
silently skip the transfer. The app never sends an absolute path or
security-scoped bookmark over the LAN.

Pairing requires a human to compare the short code. The v1 TCP transport has
message limits, replay checks, session tokens, and checksum verification but no
TLS or authenticated endpoint identity. Do not describe this LAN protocol as
end-to-end encrypted; hostile-network protection is reserved for a future
protocol version.

### Building and testing

Host-side state and protocol tests (using the macOS fallback audio driver):

```bash
swift test --package-path Apps/AudioLinkMobile -Xswiftc -warnings-as-errors
```

For a local iOS SDK compile, use the SDK and matching simulator/device triple
reported by Xcode:

```bash
IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
IOS_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-platform-version)"
swift build --package-path Apps/AudioLinkMobile \
  --sdk "$IOS_SDK" \
  --triple "arm64-apple-ios${IOS_VERSION}-simulator" \
  -Xswiftc -warnings-as-errors
```

The package manifest also contains the iOS Info.plist resources for an Xcode
application target. SwiftPM host tests do not exercise AVAudioSession, route
policy, microphone prompts, or actual speaker/microphone timing.

### Manual hardware checklist

Before calling a release measurement-ready, test on at least one recent iPhone
and one Mac, with these cases recorded in the report notes:

1. Fresh Local Network and Microphone permission grant, then denial and
   recovery through Settings.
2. Built-in speaker/microphone loopback at 44.1 and 48 kHz.
3. Wired headset or USB interface with asymmetric channel counts.
4. Bluetooth HFP route, including the negotiated sample rate and increased
   latency warning.
5. Route unplug, phone call/Siri interruption, lock-screen/background attempt,
   and app cancellation during transfer.
6. Both directions (Mac player/iPhone recorder and iPhone player/Mac recorder),
   repeated runs, checksum failure simulation, and deletion/retention policy.
7. Compare the reported delay against a known physical loopback and verify that
   the final value comes from correlation rather than network timestamps.


---

<!-- Consolidated topic section. -->

## Troubleshooting

- **File cannot be read / unsupported format:** start with a PCM16/24/32 or
  Float32 WAV, check that the file is not empty, and retry from a local folder.
- **Sample rates differ:** enable the explicit resampling option or export both
  files at the same rate. The report records that conversion occurred.
- **Low confidence / ambiguous peak:** lower ambient noise, avoid repeated
  periodic signals, capture the full reference, and widen the search range only
  when the physical setup requires it.
- **Real-time permission denied:** grant Microphone in System Settings →
  Privacy & Security. AudioLink does not request it on launch.
- **Device disconnected or route changed:** stop, reconnect the device, refresh
  the route, and start a new run. Do not mix runs across route changes.
- **Mobile peer missing:** verify Local Network permission, that both apps are
  foregrounded on the same LAN, and that the displayed pairing code matches.
- **Report export failed:** choose a writable destination with free space; no
  report is considered complete until its atomic write succeeds.


---

<!-- Consolidated topic section. -->

## Known limitations

- The LAN transport is not TLS and does not authenticate endpoint identities;
  use it only on a trusted network.
- The Mac UI does not yet provide the complete controller orchestration for the
  iPhone companion; the shared protocol and iOS responder/controller logic are
  available, but real-device interop remains a manual validation item.
- Core Audio device behavior, Bluetooth routes, feedback risk, sleep/wake,
  interruption, and iOS background limits cannot be proven on this host without
  the target hardware and permissions.
- Long-duration drift and echo diagnostics are heuristic and require acoustic
  validation against a larger corpus. They are evidence, not causal facts.
- The measured 60-second full benchmark used about 1.16 GiB peak resident
  memory for the current FFT working set; multi-minute recordings should be
  chunked/coarse-to-fine in a future release.
- The release script creates an unsigned/ad-hoc development bundle. Developer
  ID signing, provisioning, archive export, and notarization are intentionally
  developer-owned steps.
- Python/NumPy/SciPy validation and long benchmarks are optional tooling, not
  application runtime dependencies.
