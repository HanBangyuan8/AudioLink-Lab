# Spatial Impulse Response Mapper

`AudioLinkSpatial` stores a room project, source/receiver positions, a raw
impulse response, processing log, and metric validity. Coordinates are 2D with
optional height and explicit metres/feet conversion. Sparse maps show measured
points; inverse-distance interpolation is enabled only with at least three
valid samples and is labelled as an estimate.

The IR extractor is a bounded, regularized matched-filter/deconvolution fallback
for development and fixture verification. It is not a claim of IEC/ISO
compliance. EDT/RT20/RT30/RT60 are Schroeder-inspired decay fits and are marked
invalid when the requested decay range is not present, the fit has insufficient
dynamic range, or a supplied noise floor reaches the fit range. C50, C80, D50 and centre
time use explicit energy windows. Direct level is dBFS, not calibrated SPL.

Octave and one-third-octave band energy are available as standard-inspired
analysis with explicit Nyquist/bin validity. They are not declared IEC/ISO
compliant filters. Calibrated microphone correction remains future work. A
missing or uncalibrated microphone must be stated in a report; no absolute
room-acoustic certification is produced. EDT/RT20/RT30/RT60 use a Schroeder-style
reverse cumulative **energy** decay and reject a range with fewer than eight
points or R² below 0.9. C50, C80, D50 and center time use energy after the
detected direct-sound peak; pre-peak samples are not silently folded into the
late-energy baseline. The sweep extractor remains a bounded, regularized
matched-filter fallback rather than a fully calibrated inverse-sweep
implementation.
