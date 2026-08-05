# Concurrency stress

The production boundaries are actor-owned where state is mutable. The audio
callback uses `AudioLinkRealtimeSupport`, a preallocated C11-atomic,
single-producer bounded buffer; no allocation, lock, actor hop, logging, file
I/O, database I/O or network I/O occurs on the callback path.

The automated regression set covers cancellation of an in-memory transport,
repeated measurement cancellation, engine start exclusivity, concurrent SQLite
writes and bounded capture overflow. A full 100/1000-run hardware stress test
is not run in CI because it requires an attached route and TCC permission.

Run the package suite with:

```sh
bash Scripts/test-packages.sh
```

For hardware, repeat the checklist in
`Documentation/Reviews/RELIABILITY_SECURITY_REVIEW.md` while recording memory,
task, descriptor and temporary-file counts.
