# Privacy design

AudioLink Lab is local-first. It does not require an account, cloud service, or
analytics SDK.

Default history and reports retain sanitized result metadata: file names,
format, sample rate, frame counts, delay, quality, diagnostics, processing log,
and version identifiers. They do not retain complete absolute paths, home
directory names, security-scoped bookmarks, raw audio, machine serial numbers,
or network credentials. A user may choose no history, results-only history, a
managed audio copy, or an in-session bookmark; the latter two are explicit and
can be removed from Settings/History.

LAN discovery advertises only the peer name and capabilities required for
pairing. Audio is transferred only after an explicit measurement flow and is
stored in a temporary file until checksum verification. Logs must use sanitized
file names and stable error codes; they must not include raw PCM, full paths, or
bookmarks. Reports default to the same privacy filter; detailed diagnostic
identifiers are opt-in.

Microphone and Local Network permissions are requested only when the selected
workflow needs them. iOS recordings may be deleted after transfer according to
the user's retention setting. App sandbox and SQLite file permissions are
provided by the host OS; this project does not claim encrypted-at-rest storage.
