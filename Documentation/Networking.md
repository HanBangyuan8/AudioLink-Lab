# Multi-device networking foundation

`AudioLinkNetworking` is the first multi-device layer. It is a Foundation-only
package (no SwiftUI, DSP, or app target dependency) and can be reused by a
future iOS companion.

## Components

- `PeerDiscoveryService` and `BonjourPeerDiscoveryService` browse and advertise
  `_audiolink._tcp` using Network.framework. Discovery events are delivered via
  `AsyncStream` and listener/browser callbacks hop into an actor.
- `PeerConnectionProviding` exposes an async connection factory so the native
  iOS companion can connect to a discovered Mac without depending on SwiftUI.
- `PeerTransport`, `InMemoryPeerTransport`, `NetworkPeerTransport`, and
  `PeerConnection` provide framed, bounded, asynchronous transport. The memory
  transport is the deterministic test/simulation path.
- `SessionCoordinator` is an actor implementing hello, capability exchange,
  explicit short-code pairing, session configuration, prepare/ready/start/
  stop/cancel, progress/results, heartbeat, and clock messages.
- `TransferManager` streams a file in bounded chunks to a temporary file,
  verifies SHA-256, checks capacity and filename safety, then atomically moves
  it into place.
- `ClockObservation` records NTP-style `t1…t4` observations. It reports RTT and
  a clock-offset candidate only; it is not an absolute audio synchronization
  mechanism.

## Security boundary

Pairing is explicit: an unknown peer stays pending until the user compares and
confirms the six-digit code. After confirmation, the responder creates a random
session token. Every post-pairing envelope carries that token, a session ID, a
monotonic sequence, a UUID message ID, and a protocol version. `ReplayGuard`
rejects duplicate IDs and non-increasing sequence numbers. Message/file/chunk
limits and path-component checks apply before allocating or writing data.

The current `NetworkPeerTransport` uses TCP framing and **does not claim
encryption or authenticated transport**. Pairing protects accidental or
unapproved peers, not a hostile LAN or an actively spoofed endpoint. TLS with
identity pinning, key rotation, and a persisted trust decision are intentionally
reserved for a later protocol version. No security-scoped bookmark or source
audio is stored by this layer.

## Compatibility and state

The v1 envelope is JSON with sorted keys and ISO 8601 dates. Extra JSON fields
are ignored, so additive fields are forward-compatible. Unknown optional
messages are ignored; unknown critical messages are rejected safely. A version
mismatch, session mismatch, replay, malformed payload, heartbeat timeout, or
oversized transfer is a structured `ProtocolError` and never a crash.

The normal controller flow is:

```text
idle → connecting → awaitingPairing → paired → preparing → ready → running
                                                        ↘ stopping/cancelling
```

Disconnects transition to `reconnecting`; route/device changes must be handled
by the caller before resuming a measurement. A reconnect must retain the same
session token or begin a new explicit pairing. Heartbeat failure is surfaced as
an error rather than silently treating stale timestamps as audio delay.

See the wire-level field and message table in the repository root
[`PROTOCOL.md`](../PROTOCOL.md).

The iOS companion's controller/responder sequence, AVAudioSession limitations,
permission boundary, foreground requirement, and hardware checklist are in
[`MobileCompanion.md`](MobileCompanion.md).
