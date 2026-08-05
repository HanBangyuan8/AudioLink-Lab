# Performance baseline

The quick profile was run on this development host (macOS 15.7.8, Apple
Silicon arm64e, Swift 6) on 2026-08-05. Wall time is one invocation; RSS is the
process maximum and therefore grows cumulatively across rows.

| Operation | Input | Wall time |
| --- | ---: | ---: |
| Signal generation | 1 s | 17.1 ms |
| Signal generation | 10 s | 132.2 ms |
| FFT correlation | 1 s | 86.3 ms |
| FFT correlation | 10 s | 658.5 ms |
| Quality analysis | 1 s | 124.3 ms |
| Quality analysis | 10 s | 1,013.7 ms |
| Resampling | 1 s | 15.5 ms |
| Resampling | 10 s | 133.7 ms |
| Waveform min/max downsampling | 1 s | 7.8 ms |
| Waveform min/max downsampling | 10 s | 75.2 ms |
| Signal generation | 60 s | 797.9 ms |
| FFT correlation | 60 s | 4,619.7 ms |
| Quality analysis | 60 s | 6,753.8 ms |
| Resampling | 60 s | 784.2 ms |
| Waveform min/max downsampling | 60 s | 445.6 ms |
| SQLite bulk insert (100 sessions) | 100 records | 3.2 ms |
| HTML report | synthetic example | 0.5 ms |
| In-memory transport | 1 MiB | 0.02 ms |

The 60-second FFT run reached approximately 1.16 GiB maximum resident memory on
this host because the current implementation keeps full input/FFT working
sets. This is a release planning limit for longer recordings, not a promise
that arbitrary multi-minute files are safe. The 60-second profile is therefore
available for manual benchmark runs but is intentionally not part of every CI
run. These numbers are an engineering baseline, not a portable SLA. Regression review should compare
the same operation, input size, architecture, and toolchain with a generous
margin rather than failing on a single absolute threshold. Hardware audio
latency, Wi-Fi throughput, and iOS power/thermal behavior are not represented.
