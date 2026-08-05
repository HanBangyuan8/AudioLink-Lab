# Security regression fixtures

These checks exercise artifact and boundary failures without loading a
third-party plugin or opening a LAN port. `privacy_scan.py` is a dependency-free
scanner for generated reports, JSON, CSV, HTML, PNG metadata and bundle files.
It is intentionally run against an export directory, not the source tree:
documentation contains illustrative paths and loopback addresses.

Covered in package tests:

- malformed and oversized protocol envelopes;
- explicit pairing and replay checks;
- cancelled receive continuation cleanup;
- transfer checksum, temporary-file cleanup and destination path checks;
- bundle schema, checksum, duplicate-entry, symlink and expansion limits;
- SQLite migration backup and corruption preservation;
- WAV NaN/infinity rejection and configurable decoded-frame limits;
- localhost-only automation with bounded request framing and connection count.

Third-party Audio Unit isolation remains a release blocker until an actual
helper process/XPC boundary is implemented and exercised.
