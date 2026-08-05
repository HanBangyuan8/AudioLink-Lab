# Privacy and data-flow review (Prompt 28)

## Default local flow

```text
user file picker
  -> security-scoped access for the import operation only
  -> bounded Float32 importer / DSP
  -> result + diagnostics
  -> optional results-only SQLite history
  -> optional report/bundle export after an explicit privacy choice
```

The default flow does not copy the audio and does not retain a complete path or
bookmark. Explicit audio-copy/bookmark policies are validated by the storage
repository and are removable by the user.

## Network flow

```text
Bonjour name/capabilities (minimal)
  -> human pairing-code confirmation
  -> session-scoped token + bounded protocol envelope
  -> streamed temporary file + checksum
  -> atomic move into the selected destination
```

The protocol does not claim encryption. Error responses must not include a
token, absolute path or internal database location.

## Export flow

JSON/CSV/HTML/PDF/PNG and bundle exporters operate on explicit report models,
not database rows. Default anonymization removes absolute paths, home names,
bookmarks, serials, tokens and unnecessary network identifiers. Strict/public
profiles remove free text and audio where possible, but a human review warning
is still required because arbitrary notes cannot be perfectly classified.

## Audit observations

- Importer and WAV exporter error metadata now retain only the selected file
  name, not the absolute URL path.
- Bundle checksums stream in bounded chunks; manifest size is capped at 4 MiB;
  resolved symlink paths and case-folded duplicate entries are rejected.
- `Tests/SecurityRegression/privacy_scan.py` scans generated artifacts for
  `/Users/`, `file://`, IPv4 addresses, token fields and security bookmarks.
- Existing sample report and anonymous bundle pass the scanner.
- Source documentation is intentionally not scanned because it contains
  illustrative paths and loopback addresses.

## Residual privacy risks

Free-form notes, plugin license metadata, crash reports and OS-level SQLite
permissions require user/host review. The application does not claim encrypted
at-rest storage. A detailed diagnostic export must remain opt-in.
