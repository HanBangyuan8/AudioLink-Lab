# Test signal system

`AudioLinkDSP` provides a single configuration-driven entry point for
deterministic reference signals:

```swift
let configuration = TestSignalConfiguration(
    kind: .logarithmicSweep,
    sampleRate: .hz48000,
    duration: try DurationSeconds(2),
    startFrequencyHertz: 20,
    endFrequencyHertz: 20_000,
    amplitude: 0.8
)
let generated = try TestSignalGenerator().generate(configuration: configuration)
try WAVExporter().write(generated.audio, to: destinationURL)
```

## PCM convention

`AudioSampleBuffer` is normalized Float32 PCM in non-interleaved planar order:
all frames of channel zero, then all frames of channel one. `frameCount` is the
per-channel count. The type exposes peak and RMS, safe gain and normalization,
raised-cosine fades, silence concatenation, mono/stereo conversion, direct
channel access, and copy-on-write storage. `WAVExporter` interleaves only while
encoding and defaults to broadly compatible little-endian PCM Int16.

## Sweep equations

For a linear sweep of active duration `T`, starting at `f0` and ending at `f1`:

```text
f(t) = f0 + (f1 - f0)t/T
φ(t) = 2π[f0 t + (f1 - f0)t²/(2T)]
x(t) = A sin(φ(t))
```

For a logarithmic sweep, with `r = f1/f0`:

```text
f(t) = f0 exp(ln(r)t/T)
φ(t) = 2π f0 T [exp(ln(r)t/T) - 1] / ln(r)
x(t) = A sin(φ(t))
```

Both expressions calculate absolute phase from time, so phase remains
continuous for ascending and descending sweeps. `shortChirp` uses the same
continuous linear-phase equation with a caller-selected short duration.

Fade gain is a raised cosine. For `N > 1` fade-in frames:

```text
g[n] = 0.5 - 0.5 cos(πn/(N-1)), 0 ≤ n < N
```

Fade-out uses the reversed curve. This gives exact zero and unity endpoints.

## Other signals

- Maximum Length Sequence uses a deterministic Galois LFSR and primitive
  feedback masks for orders 2 through 16. The configured sequence repeats if
  active duration exceeds `2^order - 1` frames.
- Band-limited noise starts with SplitMix64 pseudorandom samples, then uses a
  129-tap-or-shorter Hann-windowed sinc band-pass FIR and vDSP convolution. It
  is peak-normalized before fades.
- Impulse contains exactly one sample. It follows pre-roll silence and, when a
  fade-in is configured, is placed immediately after that fade region so the
  pulse is not erased.
- Silence contains normalized zero samples and still participates in the same
  duration, padding, channel, polarity, and export pipeline.

## Validation and limits

All frequency fields are finite, non-negative, and no greater than Nyquist;
amplitude is finite and in `0...1`; active duration contains at least one
rounded sample; fades cannot overlap; channel count is 1...32; and allocation
arithmetic is overflow-checked. Errors are returned as
`SignalGenerationError`, `AudioSampleBufferError`, or `WAVExportError`.

The current noise FIR is designed for repeatable reference and correlation
work, not mastering-grade brick-wall filtering. MLS orders above 16, RF64 WAV
files larger than 4 GiB, arbitrary multichannel downmix matrices, shaped noise,
and inverse-sweep/deconvolution filters are intentionally deferred.

See `Validation/README.md` for the optional Python waveform, spectrogram, and
frequency-trajectory verification workflow.
