# AudioLink Mobile companion

`Apps/AudioLinkMobile` is a native SwiftUI iOS companion. It reuses
`AudioLinkCore`, `AudioLinkDSP`, and `AudioLinkNetworking`; no shared algorithm
is copied into the app target. The mobile target is intentionally a small
companion surface, not a second copy of the macOS application.

## Roles and flow

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

## iOS audio behavior

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

## Recording retention and privacy

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

## Building and testing

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

## Manual hardware checklist

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
