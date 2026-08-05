# First-use guide

For a file measurement, open **New Measurement**, choose a reference WAV and a
recording WAV, leave the conservative defaults in **Configure**, and press
**Analyze**. The result is a correlation-derived delay in samples and
milliseconds plus quality level, peak, polarity, warnings, and processing log.
Changing either file or a relevant option invalidates the old result.

For a same-Mac real-time run, choose the output and input devices, lower the
volume, confirm the feedback warning, grant microphone access when prompted,
then start. Capture begins before playback; software scheduling timestamps are
diagnostics only. Stop or cancel at any time.

History is local SQLite and results-only by default. Reports are privacy-filtered
unless detailed identifiers are explicitly enabled. The iOS companion requires
the app in the foreground, microphone and Local Network permission, explicit
pairing, and a trusted LAN; network timestamps schedule a capture window but do
not replace acoustic correlation.
