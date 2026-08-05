# Troubleshooting

- **File cannot be read / unsupported format:** start with a PCM16/24/32 or
  Float32 WAV, check that the file is not empty, and retry from a local folder.
- **Sample rates differ:** enable the explicit resampling option or export both
  files at the same rate. The report records that conversion occurred.
- **Low confidence / ambiguous peak:** lower ambient noise, avoid repeated
  periodic signals, capture the full reference, and widen the search range only
  when the physical setup requires it.
- **Real-time permission denied:** grant Microphone in System Settings →
  Privacy & Security. AudioLink does not request it on launch.
- **Device disconnected or route changed:** stop, reconnect the device, refresh
  the route, and start a new run. Do not mix runs across route changes.
- **Mobile peer missing:** verify Local Network permission, that both apps are
  foregrounded on the same LAN, and that the displayed pairing code matches.
- **Report export failed:** choose a writable destination with free space; no
  report is considered complete until its atomic write succeeds.
