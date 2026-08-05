# Audio file import and preprocessing

AudioLinkDSP imports user-selected audio into the same canonical
`AudioSampleBuffer` used by the signal generator: normalized Float32,
non-interleaved planar PCM. File parsing and preprocessing do not import
SwiftUI and execute in cancellable detached tasks.

## Verified format matrix

The following combinations are generated during the test run and decoded back
through the production importer. This table describes verified behavior, not
every format that AVFoundation might theoretically open.

| Container | Encoding | Channels | Tested sample rate | Decoder |
| --- | --- | --- | --- | --- |
| WAV | signed PCM 16-bit | mono and stereo | 48 kHz mono, 44.1 kHz stereo | AudioLink native WAV |
| WAV | signed PCM 24-bit | mono and stereo | 48 kHz mono, 44.1 kHz stereo | AudioLink native WAV |
| WAV | signed PCM 32-bit | mono and stereo | 48 kHz mono, 44.1 kHz stereo, 96 kHz one-frame boundary | AudioLink native WAV |
| WAV | IEEE Float 32-bit | mono and stereo | 48 kHz mono, 44.1 kHz stereo | AudioLink native WAV |
| AIFF | signed PCM 16-bit | mono | 44.1 kHz | AVFoundation fallback |
| CAF | IEEE Float 32-bit | mono | 44.1 kHz | AVFoundation fallback |
| M4A | AAC | mono | 44.1 kHz | AVFoundation fallback |

WAV files are decoded in bounded chunks from interleaved little-endian file
data directly into planar Float PCM. The complete decoded Float buffer is kept
in memory because downstream correlation requires random access. AIFF, CAF, and
M4A use AVFoundation and are limited to the combinations above for the current
verified support claim.

## Import API

```swift
let imported = try await AudioFileImporter().importFile(
    at: selectedURL,
    progress: { progress in
        // This callback runs on a worker. Hop to MainActor before changing UI.
        Task { @MainActor in
            model.importProgress = progress.fractionCompleted
        }
    }
)
```

`AudioFileImporter` implements `AudioDecodingService`. It starts security-scoped
access only for the duration of an import and always stops it afterward. The
current milestone intentionally creates no persistent bookmark and retains no
long-term permission. A future SwiftUI `.fileImporter` should pass its selected
URL directly to this API.

`ImportedAudioFile` includes source URL/name, original on-disk format, canonical
internal format, sample rate, channel/frame counts, duration, peak, RMS,
clipping count, overall/per-channel DC offset, metadata, and preprocessing log.

## Explicit preprocessing

Every transformation is opt-in through `PreprocessingConfiguration`. Requested
operations run in this documented order:

1. select a zero-based channel;
2. downmix stereo to mono;
3. remove per-channel DC offset;
4. trim leading silence;
5. trim trailing silence;
6. apply a second-order Butterworth high-pass filter;
7. resample with `AVAudioConverter`;
8. invert polarity;
9. apply safe linear gain;
10. peak normalize or RMS normalize.

Channel selection and downmix are mutually exclusive. Peak and RMS
normalization are mutually exclusive. Safe gain and RMS normalization fail with
`operationWouldClip` rather than silently clipping. Silence trimming requires
an explicit amplitude threshold and optional minimum duration.

Each actual transformation appends a `PreprocessingLogEntry` containing its
sequence, parameters, and input/output frame counts. `wasResampled` is derived
from this log. Supplying no operations returns sample-identical audio and an
unchanged log.

Apple sample-rate conversion uses an output capacity equal to:

```text
round(inputFrameCount × destinationSampleRate / sourceSampleRate)
```

This excludes converter filter-tail frames from the analysis timeline. The
pipeline verifies that resulting duration differs by no more than one output
frame and records both frame counts and sample rates.

## Developer CLI

Inspect a file and print a sorted JSON report:

```bash
swift run --package-path Packages/AudioLinkDSP AudioLinkAudioFileTool input.wav
```

Apply explicit preprocessing and export PCM24 WAV plus a JSON report:

```bash
swift run --package-path Packages/AudioLinkDSP AudioLinkAudioFileTool input.wav \
  --downmix-mono --remove-dc --high-pass 20 --sample-rate 48000 \
  --peak-normalize 0.8 --encoding pcmInt24 \
  --output /tmp/processed.wav --json-output /tmp/processed.json
```

The CLI refuses to overwrite its input file.

## Current limits

- Native WAV support is little-endian RIFF only; RF64, Wave64, RIFX, packed
  non-byte-aligned PCM, and more than two channels are rejected.
- WAV LIST/INFO and BWF metadata are not parsed yet. Metadata currently records
  decoder and file-size context.
- The complete canonical Float buffer must fit in process memory. Import is
  asynchronous, chunked, cancellable, and reports progress, but is not a
  disk-backed streaming analysis implementation.
- AVFoundation fallback behavior can vary with OS codec availability. Only the
  exact AIFF, CAF, and M4A fixtures in the verified table are claimed.
- Resampling currently allocates complete input and output `AVAudioPCMBuffer`
  objects. Multi-hour recordings will need segmented SRC before that workload
  is considered production-supported.
- No security-scoped bookmarks or permanent external-file access are stored.
