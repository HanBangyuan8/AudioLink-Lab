# `.audiolinkbundle` format

AudioLink bundles are directory packages with a `.audiolinkbundle` extension.
The format is deliberately independent of SQLite internals and can be opened
by both CLI and GUI code.

```text
example.audiolinkbundle/
  manifest.json
  results/result.json
  charts/...
  audio/              # absent unless explicitly selected
```

Manifest schema `1.0` includes bundle ID, ISO-8601 creation date, app,
algorithm, protocol, measurement type, privacy/anonymization level, required
capabilities, validation status, and an inventory of relative paths, sizes and
SHA-256 checksums. A signature field is reserved but no signature is claimed in
this release.

The writer stages a temporary directory and moves it into place only after all
files and the manifest have been written. The validator rejects unsupported
schema versions, duplicate entries, absolute or traversal paths, missing
required files, size mismatches, checksum mismatches, and expansion beyond its
configured limit. No HTML or script is executed while validating a bundle.

Audio is opt-in. Minimal, Standard and Strict privacy levels are represented in
the manifest; Strict exports should still be manually reviewed because free
text cannot be perfectly anonymized by a generic sanitizer.

`Examples/anonymous-example.audiolinkbundle` is a synthetic,
checksum-verified fixture containing only an anonymized result JSON; it contains
no audio, absolute path, token, or hardware identifier.
