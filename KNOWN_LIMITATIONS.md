# Known limitations

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
