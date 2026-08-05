# Audio Interface Benchmark Lab

`BenchmarkPlan`, `BenchmarkMatrixBuilder`, `BenchmarkRunner`, and the result models separate:

* reported Core Audio input/output, safety-offset and stream latency;
* theoretical `2 × buffer + input + output + safety + stream` frames;
* correlation-measured latency;
* unexplained measured-minus-theoretical frames.

Only advertised sample-rate and buffer combinations are generated. `AudioDeviceConfigurationTransaction` captures, applies, waits for stability, confirms, and restores settings on normal and cancellation paths. The runner does not write SQLite or update UI from an audio callback.

Physical loopback, Bluetooth, aggregate, and virtual-driver behaviour require manual testing. The application does not change the default route without an explicit user action and makes no electrical safety claims about cabling.
