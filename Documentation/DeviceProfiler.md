# Core Audio Device Profiler

`AudioLinkRealtime` exposes `AudioPropertyProvider`, `AudioDeviceProfiler`, and `AudioDeviceSnapshot`. The provider is the only layer that constructs native `AudioObjectPropertyAddress` values; snapshot and UI layers use typed, scope-aware values.

The macOS provider reads device identity, transport, clock domain, alive/running state, stream configuration, nominal and advertised sample rates, buffer size/range, safety offset, and global/input/output latency. Missing properties are capability gaps, not fatal errors. OSStatus failures retain the operation and property address in `AudioDevicePropertyError`.

Selectors currently mapped: `kAudioHardwarePropertyDevices`, `kAudioObjectPropertyName`, `kAudioObjectPropertyManufacturer`, `kAudioDevicePropertyDeviceUID`, `kAudioDevicePropertyModelUID`, `kAudioDevicePropertyTransportType`, `kAudioDevicePropertyClockDomain`, `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyDeviceIsRunning`, `kAudioDevicePropertyNominalSampleRate`, `kAudioDevicePropertyAvailableNominalSampleRates`, `kAudioDevicePropertyBufferFrameSize`, `kAudioDevicePropertyBufferFrameSizeRange`, `kAudioDevicePropertySafetyOffset`, `kAudioDevicePropertyLatency`, `kAudioDevicePropertyStreamConfiguration`, `kAudioDevicePropertyHogMode`, volume/mute, data-source, and clock-source capability selectors.

Snapshots distinguish advertised capabilities from verification (`verified` remains `nil` until an explicit safe format/engine check). Snapshot JSON can be stored in SQLite schema v5 through `DeviceSnapshotRecord`; callers choose anonymisation before export.

Change monitoring is actor-owned and coalesces snapshot changes. Core Audio listener blocks are owned by the provider and removed/replaced by address; callbacks only schedule work. The bounded polling fallback avoids property reads on a HAL callback.

Manual hardware checklist: built-in speaker, built-in microphone, USB class-compliant interface, Bluetooth headset, BlackHole/Loopback virtual device, Aggregate Device, and Multi-Output Device. Automated tests use a mock provider and do not constitute hardware verification.

Known limits: control elements (volume/mute/data source), aggregate sub-device drift compensation, stream physical format ranges, hog mode ownership, and independent-clock claims are modelled but not populated by the first provider pass.
