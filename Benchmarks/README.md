# AudioLink Lab benchmarks

`AudioLinkBenchmarks` is a macOS-only executable that measures wall time and
`ru_maxrss` (maximum resident set size) for the shared DSP, import/preprocessing,
visualization, SQLite, report, and in-memory transfer paths. Each row records
the duration, input frame/byte count, platform string, and the operation name.

Run a repeatable smoke profile:

```bash
./Scripts/run-benchmarks.sh quick
```

Run the 1 s / 10 s / 60 s profile (the 60 s correlation case is intentionally
more expensive):

```bash
./Scripts/run-benchmarks.sh full Benchmarks/results/full.json
```

The benchmark is a diagnostic baseline, not a CI pass/fail gate. CI machines
vary in CPU, thermal state, and memory pressure, so regression review should
compare the same operation and input size with a generous margin. A future
release may add a machine-specific baseline after collecting several runs.

The transfer row measures the actor-isolated in-memory transport used by tests;
it does not claim to represent Wi-Fi throughput. Hardware audio, Core Audio
route changes, iOS interruption behavior, signing, and notarization require the
manual checklist in `Documentation/ReleaseAudit.md`.
