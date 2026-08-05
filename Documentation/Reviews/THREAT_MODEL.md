# AudioLink Lab threat model (Prompt 28)

## Scope and trust boundaries

AudioLink Lab has four materially different boundaries:

1. **User-selected files → importer/DSP.** WAV, AVFoundation-supported files,
   reports and bundles are untrusted bytes. The importer must validate sizes,
   frame alignment, finite samples and supported formats before allocating or
   processing. Bundle metadata is data, never executable code.
2. **GUI/CLI/localhost automation → measurement core.** These are local callers,
   not a security boundary by themselves. Automation is opt-in, binds to
   loopback, requires a token and an allow-list, and is bounded by request and
   job limits.
3. **LAN peer → networking/session/transfer.** The LAN is hostile. Bonjour
   names are display hints, not identities. Pairing requires a human code
   confirmation; envelopes carry session IDs, sequence numbers and a token;
   frames/files are size bounded and checksummed. The current protocol is not
   TLS and does not provide authenticated encryption or forward secrecy.
4. **Core Audio/plugin/device callbacks → app state.** Core Audio callbacks and
   third-party plugins can fail asynchronously. Callback work is bounded and
   non-blocking; plugin execution is currently *not* process isolated (see
   blockers below), so untrusted plugins must not be treated as safe.

## Assets

- raw recordings and reference signals;
- user file names, notes and device identifiers;
- calibration/history/database contents;
- pairing/session tokens and transferred files;
- device configuration (sample rate/buffer size);
- measurement integrity and reported delay.

## Adversaries and abuse cases

- malformed WAV/JSON/bundle inputs causing oversized allocations, traversal,
  zip-bomb-like expansion or NaN propagation;
- an unpaired or compromised peer replaying commands, changing runs, flooding
  messages or claiming another file;
- a local process guessing the automation token or submitting paths outside the
  allow-list;
- device removal, interruption, cancellation or process termination during
  configuration;
- a plugin that crashes, hangs, allocates without bound or emits non-finite
  samples;
- logs/reports containing absolute paths, bookmarks, network addresses or
  free-form personal notes.

## Current guarantees

- offline file analysis does not open a network listener;
- importer and bundle validator have explicit expansion/decoded-frame limits;
- WAV Float32 NaN/Infinity is rejected;
- transfers stream to a random `.part` file, check size/checksum and move without
  overwriting an existing destination;
- migration creates a pre-migration SQLite sidecar before changing an existing
  database and uses transactional schema changes;
- audio tap capture is preallocated and lock-free on the producer path;
- cancelled in-memory receives remove their continuation rather than leaving a
  waiter behind;
- automation framing is bounded, loopback-only, token-gated and limited to
  eight simultaneous connections.

These are implementation claims covered by the tests listed in the reliability
review; they are not a claim of formal security certification.

## Explicit non-guarantees / blockers

- no TLS, certificate pinning, authenticated peer identity or forward secrecy;
- third-party Audio Units still run through the injected in-process runner; a
  hanging or crashing real plugin can therefore affect the host. A helper
  process/XPC boundary is required before calling plugin profiling safe;
- Core Audio restoration after power loss, process kill or hardware unplug is
  not mechanically guaranteed; hardware verification remains manual;
- free-form text anonymization is heuristic and must be reviewed before public
  export;
- iOS and real LAN/hardware stress paths were not exercised in this sandbox.
