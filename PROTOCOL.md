# AudioLink Lab measurement protocol v1

This document defines the first LAN protocol implemented by
`AudioLinkNetworking`. It is a versioned control and file-transfer protocol for
simulated peers and future Apple-device measurements. It is not an audio stream
transport and network timestamps are never substituted for acoustic delay.

## Envelope

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

## Message kinds

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

## State machine

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

## Mobile controller schedule

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

## File transfer

Transfers are streamed in chunks (default 64 KiB, maximum 256 KiB). The receiver
rejects oversized files, unsafe path components, unexpected indexes, extra
bytes, insufficient free space, mismatched session/token, duplicate messages,
or an incorrect SHA-256. Data is written to a random `.part` file and moved
atomically only after verification. Cancellation, disconnect, checksum failure,
or malformed input removes the temporary file. The default maximum file size is
2 GiB; callers can lower it for a session.

## Clock observations

For a ping-pong exchange, `t1` is the local send time, `t2` remote receive,
`t3` remote send, and `t4` local receive. The implementation reports:

```text
RTT = t4 - t1
offset candidate = ((t2 - t1) - (t4 - t3)) / 2
```

These values assume roughly symmetric network delay and are diagnostic inputs
for a later drift model. They do not represent speaker/microphone latency.

## Threat model and future compatibility

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

## Distributed sessions

`AudioLinkDistributed` layers a coordinator-owned star session above this
envelope. Each assignment has a node UUID and explicit role; a coordinator
must receive `ready` from all required nodes before `armed`/`start`. A session
ID is checked on every control message, so stale messages cannot affect a new
session. Nodes may upload summaries before large recordings; file retention is
an explicit plan choice. The node model records capability, heartbeat, RTT,
clock offset/drift and per-source uncertainty. It does not turn network time
into acoustic arrival time and does not add an end-to-end encryption claim.
