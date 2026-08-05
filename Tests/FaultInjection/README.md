# Fault-injection scenarios

Faults are injected at package boundaries rather than by changing the audio
callback or swallowing errors. The current automated fixtures cover cancelled
imports, malformed WAVs, NaN/Infinity samples, protocol replay/oversize,
interrupted transfers, checksum failure, SQLite transaction rollback,
migration/corruption preservation and helper-runner failure responses.

The following require an explicit manual run on hardware or with a separate
helper process and are recorded as **unverified**: sleep/wake during capture,
device hot-unplug during a configuration transaction, full-disk export,
Core-Audio route restoration after process termination, and crashing/hanging
third-party Audio Units. They must not be described as release-tested.
