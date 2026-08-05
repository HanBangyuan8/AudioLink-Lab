# Real-time Measurement

The first real-time mode measures a same-Mac path by playing a deterministic
test signal through one Core Audio output, recording one Core Audio input, and
running the existing offline correlation and quality engines on the capture.
It supports acoustic speaker-to-microphone paths, hardware interface loopback,
and virtual-device chains without routing the captured input back to the output.

## Package boundary

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

The package also composes this single-run engine into repeated plans. See
[RepeatedMeasurements.md](RepeatedMeasurements.md) for pause/resume semantics,
statistics, outlier rules, visualization, and persistence behavior.

The application injects a results-only SQLite saver. No absolute device-related
path or captured PCM is stored. Complete engine diagnostics are encoded into the
run processing log alongside the normal preprocessing operations.

## Sequence and timing truth

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

## Route policy

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

## Real-time memory behavior

Before starting the engine, AudioLink preallocates capture storage for pre-roll,
the full generated signal, post-roll, and eight additional I/O buffers. The tap
does not append Swift arrays, lock shared UI state, run DSP, write files, or
allocate per buffer. It copies the selected Float32 channel into bounded storage
and updates counters. Exceeding that capacity increments `overflowCount` and
truncates only the excess frames; quality and diagnostics then make the run
inspectable rather than crashing.

## Safety and permissions

The microphone prompt is not shown at launch or during signal preview. It is
requested only after the user starts a real-time measurement. A denied result
includes the System Settings recovery path.

The default logarithmic sweep uses about 18% normalized amplitude (roughly
−15 dBFS), 80 Hz to the lower of 18 kHz or 45% of sample rate, and short raised
cosine fades. The UI requires explicit volume and feedback acknowledgements.
AudioLink does not connect the input node to the mixer, but users must still
avoid feedback in external interfaces, virtual routers, and acoustic paths.

## Automated validation

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

## Manual hardware validation still required

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
