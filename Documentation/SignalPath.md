# Signal Path Measurement Mode

`AudioLinkSignalPath` stores an explicit graph of devices, applications, plugin chains and physical processors. External DAW nodes can be described manually; the app does not pretend to inspect every DAW bus or plugin chain.

Four modes are represented: continuous capture, scheduled window, repeated marker, and offline file round-trip. Deterministic start/calibration/main/timing/end markers carry a session UUID and marker version as machine-readable metadata; they are not an inaudible watermark. Marker detection reports missing start/end, incomplete capture, version mismatch and correlation confidence so callers can warn rather than make a causal claim. `PathComparison` keeps sample-rate differences explicit.

Generic templates can describe Logic Pro, Ableton Live, Reaper, OBS, BlackHole and physical inserts, but no software-version behaviour is hard-coded. Manual validation remains required for DAW delay compensation, live monitoring, offline bounce alignment and virtual-device resampling.
