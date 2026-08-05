# AudioLink Lab security and data

This reference consolidates privacy, security, protocol, bundle, automation, and data-handling documentation.


---

<!-- Consolidated topic section. -->

## Privacy design

AudioLink Lab is local-first. It does not require an account, cloud service, or
analytics SDK.

Default history and reports retain sanitized result metadata: file names,
format, sample rate, frame counts, delay, quality, diagnostics, processing log,
and version identifiers. They do not retain complete absolute paths, home
directory names, security-scoped bookmarks, raw audio, machine serial numbers,
or network credentials. A user may choose no history, results-only history, a
managed audio copy, or an in-session bookmark; the latter two are explicit and
can be removed from Settings/History.

LAN discovery advertises only the peer name and capabilities required for
pairing. Audio is transferred only after an explicit measurement flow and is
stored in a temporary file until checksum verification. Logs must use sanitized
file names and stable error codes; they must not include raw PCM, full paths, or
bookmarks. Reports default to the same privacy filter; detailed diagnostic
identifiers are opt-in.

Microphone and Local Network permissions are requested only when the selected
workflow needs them. iOS recordings may be deleted after transfer according to
the user's retention setting. App sandbox and SQLite file permissions are
provided by the host OS; this project does not claim encrypted-at-rest storage.


---

<!-- Consolidated topic section. -->

## Security policy

AudioLink Lab is a local measurement tool. The current LAN implementation uses
bounded TCP framing, explicit user pairing, a short-code confirmation, session
tokens, replay checks, path validation, and SHA-256 file checksums. It does not
provide TLS, authenticated peer identities, forward secrecy, or protection from
a hostile or compromised local network. Do not describe v1 as end-to-end
encrypted.

The default offline workflow does not open a listening network service. The
Bonjour/mobile workflow is opt-in and should only be used on a trusted LAN.
Unknown peers require an explicit user confirmation; a matching device name is
not proof of identity. File transfers are written to a random temporary file,
verified, and atomically moved; interrupted transfers are removed.

Please report security issues privately to the repository owner before opening a
public issue. Include the affected version, platform, reproducible steps, and a
minimal redacted log. Never attach a recording or security-scoped bookmark.

Until a signed release process and TLS identity pinning are available, the
recommended deployment is an unsigned development build on a trusted machine,
with networking disabled when it is not needed.


---

<!-- Consolidated topic section. -->

## Local automation security

The local automation service is optional and is not started by the app, CLI, or
login session. When explicitly started it binds a TCP listener to the IPv4
loopback endpoint (`127.0.0.1`) and enables `acceptLocalOnly`; it does not
advertise Bonjour or listen on a LAN interface.

Every request requires a per-process random bearer token. The token is not
written to reports, history, logs, or example files. Requests are size-limited,
jobs are concurrency-limited, and the service exposes only health, job status,
result, and cancellation routes.

File analysis accepts paths only under directories explicitly supplied when the
service is created. Paths are standardized and resolved through symlinks before
the allowed-root prefix check; `..`, absolute paths outside the root, and
symlink escapes are rejected. The service never provides an arbitrary file-read
or directory-listing endpoint.

The service keeps a bounded in-memory history (100 terminal jobs) and does not
persist input paths or recordings by default. Active jobs are still retained
until they reach a terminal state. Callers should use an application-container
directory or a security-scoped selection they already own. Localhost access is
not a substitute for OS user authentication: another process running as the
same user may be able to inspect the token or connect to the service. TLS and
remote authentication are intentionally not claimed.


---

<!-- Consolidated topic section. -->

## AudioLink Lab measurement protocol v1

This document defines the first LAN protocol implemented by
`AudioLinkNetworking`. It is a versioned control and file-transfer protocol for
simulated peers and future Apple-device measurements. It is not an audio stream
transport and network timestamps are never substituted for acoustic delay.

### Envelope

Each JSON message contains these fields:

| Field | Meaning |
| --- | --- |
| `messageID` | UUID unique for this message; used by the replay guard. |
| `sessionID` | Measurement session UUID. The responder learns it from `hello`. |
| `protocolVersion` | Current value `1.0`. |
| `sentAt` | ISO-8601 wall-clock send time for diagnostics only. |
| `sequence` | Sender-local monotonically increasing sequence number. |
| `sessionToken` | Random token after pairing; absent during hello/pairing. |
| `kind` | Message kind from the table below. |
| `critical` | If true, an unknown kind is a hard protocol error. |
| `payload` | JSON-encoded message-specific object. |

The codec uses sorted JSON keys, ISO-8601 dates, and a 1 MiB default envelope
limit. Unknown fields are ignored. Unknown optional messages are ignored;
unknown critical messages are rejected with `unknownCriticalMessage`.

### Message kinds

| Kind | Payload purpose |
| --- | --- |
| `hello` | `PeerIdentity` and a random nonce. |
| `capabilityAdvertisement` | Roles, sample rates, and file/clock capabilities. |
| `pairingRequest` / `pairingResponse` | SHA-256 digest of the displayed six-digit code; acceptance returns a session token. |
| `sessionConfiguration` | Sample rate, frame count, and explicit key/value settings. |
| `prepare` / `ready` | Run UUID and participating roles. |
| `start` / `stop` / `cancel` | Run control and optional reason. `start` may include a relative delay, sender host time, pre/post-roll samples, and negotiated sample rate. |
| `eventTimestamp` | Host/sample event observations (diagnostics, not final delay). |
| `progress` | Bounded 0…1 progress and optional text. |
| `resultSummary` | Delay, quality label, and sanitized details. |
| `error` | Stable code, user message, technical details, retryability. |
| `heartbeat` | Sequence heartbeat used for liveness. |
| `fileTransferStart` | Safe filename, byte size, chunk size, SHA-256, transfer UUID. |
| `fileChunk` | Transfer UUID, zero-based index, bounded `Data` chunk. |
| `fileTransferComplete` | Transfer UUID; receiver verifies length and checksum first. |
| `clockPing` / `clockPong` | Four-timestamp clock observation exchange. |

Roles are `controller`, `responder`, `recorder`, and `player`. A peer may
advertise several roles; the initial implementation does not require a role to
map one-to-one to a device.

### State machine

```text
idle → connecting → awaitingPairing → paired → preparing → ready → running
  ↑                                      ↘ stopping / cancelling
  └──────────── reconnecting ← disconnect/heartbeat timeout
```

The controller sends hello/capabilities and a pairing request. The responder
must ask its user to compare the code and call `acceptPairing`; it may instead
reject. Only paired peers may exchange configuration and run control. Any
device or route change must stop the run and be explicitly revalidated before a
new run.

### Mobile controller schedule

`Apps/AudioLinkMobile` uses the same envelope for an iPhone controller or
responder. The controller sends `sessionConfiguration` with a serialized mobile
plan, then `prepare`/`ready`, followed by `start`. The optional scheduling fields
are deliberately relative: `scheduledAfterNanoseconds` tells the peer to wait
before starting, while `localHostTimeNanoseconds` records the sender's local
reference for diagnostics. `preRollSamples` and `postRollSamples` define the
capture window and `sampleRateHertz` records the negotiated rate.

The responder must start capture before playback, keep the pre/post-roll window,
and stop safely on interruption or route change. A recorder sends its WAV using
the chunked transfer messages; the receiver verifies the checksum and atomically
moves the temporary file. The Mac remains responsible for importing that file
and running the final correlation. These schedule and network clock fields are
not a substitute for a shared hardware clock or an acoustic delay estimate.

### File transfer

Transfers are streamed in chunks (default 64 KiB, maximum 256 KiB). The receiver
rejects oversized files, unsafe path components, unexpected indexes, extra
bytes, insufficient free space, mismatched session/token, duplicate messages,
or an incorrect SHA-256. Data is written to a random `.part` file and moved
atomically only after verification. Cancellation, disconnect, checksum failure,
or malformed input removes the temporary file. The default maximum file size is
2 GiB; callers can lower it for a session.

### Clock observations

For a ping-pong exchange, `t1` is the local send time, `t2` remote receive,
`t3` remote send, and `t4` local receive. The implementation reports:

```text
RTT = t4 - t1
offset candidate = ((t2 - t1) - (t4 - t3)) / 2
```

These values assume roughly symmetric network delay and are diagnostic inputs
for a later drift model. They do not represent speaker/microphone latency.

### Threat model and future compatibility

The implementation protects against accidental unapproved peers, stale/replayed
messages within the bounded replay window, oversized allocations, path
traversal, and transfer corruption. It does **not** provide TLS, endpoint
identity authentication, forward secrecy, protection against a malicious LAN
observer, or protection against a compromised host. The protocol must not be
described as end-to-end encrypted until a future version adds TLS with explicit
identity validation and a migration story.

Additive fields are safe in v1. A future incompatible change increments the
major protocol version and must be rejected rather than guessed. Reports and
local history remain usable if networking is unavailable.

### Distributed sessions

`AudioLinkDistributed` layers a coordinator-owned star session above this
envelope. Each assignment has a node UUID and explicit role; a coordinator
must receive `ready` from all required nodes before `armed`/`start`. A session
ID is checked on every control message, so stale messages cannot affect a new
session. Nodes may upload summaries before large recordings; file retention is
an explicit plan choice. The node model records capability, heartbeat, RTT,
clock offset/drift and per-source uncertainty. It does not turn network time
into acoustic arrival time and does not add an end-to-end encryption claim.


---

<!-- Consolidated topic section. -->

## `.audiolinkbundle` format

AudioLink bundles are directory packages with a `.audiolinkbundle` extension.
The format is deliberately independent of SQLite internals and can be opened
by both CLI and GUI code.

```text
example.audiolinkbundle/
  manifest.json
  results/result.json
  charts/...
  audio/              # absent unless explicitly selected
```

Manifest schema `1.0` includes bundle ID, ISO-8601 creation date, app,
algorithm, protocol, measurement type, privacy/anonymization level, required
capabilities, validation status, and an inventory of relative paths, sizes and
SHA-256 checksums. A signature field is reserved but no signature is claimed in
this release.

The writer stages a temporary directory and moves it into place only after all
files and the manifest have been written. The validator rejects unsupported
schema versions, duplicate entries, absolute or traversal paths, missing
required files, size mismatches, checksum mismatches, and expansion beyond its
configured limit. No HTML or script is executed while validating a bundle.

Audio is opt-in. Minimal, Standard and Strict privacy levels are represented in
the manifest; Strict exports should still be manually reviewed because free
text cannot be perfectly anonymized by a generic sanitizer.

`Examples/anonymous-example.audiolinkbundle` is a synthetic,
checksum-verified fixture containing only an anonymized result JSON; it contains
no audio, absolute path, token, or hardware identifier.


---

<!-- Consolidated topic section. -->

## CLI and local automation

The CLI is a thin executable target over existing AudioLink packages. The
headless file analyzer imports WAV/AVFoundation files and calls the existing
`CorrelationEngine`; it does not reimplement DSP. JSON output uses a stable
`schemaVersion` and never mixes progress text into stdout when `--json` is set.

The optional local HTTP service is started explicitly by embedding code. It is
loopback-only, requires a random bearer token, has request and concurrency
limits, and accepts only paths below caller-supplied allowed directories. It is
an automation convenience, not a remote control plane or an encryption claim.

Plans use JSON schema `1.0`. Unsupported versions fail before execution. Batch
file analysis can continue after an individual failure and writes one result per
input when an output directory is supplied. Existing files are not overwritten
by the plan adapter unless a future explicit overwrite policy is added.
