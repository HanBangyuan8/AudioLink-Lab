# AudioLink Lab v1.0.0

AudioLink Lab v1.0.0 is the first public package of the native Apple-platform
audio measurement toolkit.

## Included

- macOS SwiftUI file-analysis workflow for two WAV files
- Deterministic test signals and Float32 PCM processing
- Direct/FFT correlation with delay, peak, polarity, and quality diagnostics
- Waveform/correlation visualization and PNG export
- SQLite history, repeated measurements, calibration, and drift analysis
- Same-Mac realtime loopback foundations and an iOS companion target
- Versioned reports, anonymous bundles, CLI automation, and validation tools

## Install

Download the macOS archive from the GitHub Releases page and unzip it. The
package is an ad-hoc/unsigned development distribution unless a developer has
provided their own signing and notarization credentials.

## Build from source

```bash
./Scripts/test-packages.sh
./Scripts/build-all.sh
AUDIO_LINK_VERSION=1.0.0 AUDIO_LINK_BUILD_VERSION=1 ./Scripts/package-app.sh release
```

## Privacy

Results-only history and reports are the default. Raw audio, absolute paths,
bookmarks, and detailed hardware identifiers require explicit user choice.
Free-form notes should be reviewed before public sharing. See `PRIVACY.md` and
`SECURITY.md`.

## Important limitations

- The LAN protocol is pairing-protected but not TLS-authenticated; use it only
  on a trusted local network.
- Third-party Audio Units are not yet isolated in a helper process. Do not load
  untrusted plugins.
- Physical Core Audio recovery, iOS interruption behavior, sleep/wake, disk-full
  handling, and long hardware soak tests require manual validation.
- Advanced device, DAW, plugin, spatial, and distributed modules are foundations
  and diagnostics, not certification tools.

## Reproducibility

The result records app/build, algorithm, protocol, report, bundle, automation,
and database versions independently. Python reference implementations and
deterministic examples are in `Validation/` and `Examples/`.

## License

Mozilla Public License 2.0. See `LICENSE`.
