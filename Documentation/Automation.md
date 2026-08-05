# CLI and local automation

The CLI is a thin executable target over existing AudioLink packages. The
headless file analyzer imports WAV/AVFoundation files and calls the existing
`CorrelationEngine`; it does not reimplement DSP. JSON output uses a stable
`schemaVersion` and never mixes progress text into stdout when `--json` is set.

The optional local HTTP service is started explicitly by embedding code. It is
loopback-only, requires a random bearer token, has request and concurrency
limits, and accepts only paths below caller-supplied allowed directories. It is
an automation convenience, not a remote control plane or an encryption claim.

Plans use JSON schema `1.0`. Unsupported versions fail before execution. Batch
file analysis can continue after an individual failure and writes one result per
input when an output directory is supplied. Existing files are not overwritten
by the plan adapter unless a future explicit overwrite policy is added.
