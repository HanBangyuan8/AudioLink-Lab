# Measurement visualization

AudioLink Lab's measurement review uses SwiftUI `Canvas`, Core Graphics, and
small immutable render models. It does not depend on a third-party chart
library, and the drawing layer never receives `ImportedAudioFile`, file URLs, or
the full measurement-quality object.

## Result organization

The completed measurement view is divided into five finite sections:

- **Summary**: canonical delay, integer/fractional samples, sample rate,
  correlation, polarity, quality, and important warnings.
- **Waveforms**: split reference and recording tracks, before/after alignment,
  sample/time cursor, delay marker, zoom, pan, and PNG export.
- **Correlation**: signed correlation, sample/millisecond lag axes, search
  boundaries, confidence thresholds, primary/secondary/candidate peaks,
  selection, and an explicit search-edge warning.
- **Diagnostics**: the explainable quality components, warnings, and recommended
  actions.
- **Processing Log**: only explicitly applied preprocessing operations and
  frame-count changes. Paths are deliberately excluded.

The peak-detail plot shows the integer samples around the selected peak, the
three-point parabolic interpolation curve, integer and fractional markers,
measured peak width, local noise-floor RMS, and confidence metrics.

## Render-model boundary

`VisualizationModels.swift` defines the platform-neutral values consumed by
the app:

- `WaveformRenderData` and `WaveformTrackRenderData`
- `CorrelationRenderData`
- `PeakDetailRenderData`
- `PlotViewport` and `PlotMarker`
- `DownsamplingStrategy`

These models are `Codable`, `Equatable`, and `Sendable`. Sample positions and
lags remain in sample units; explicit sample-rate conversion supplies seconds
and milliseconds. This keeps plotting independent from importing, analysis,
and SwiftUI.

## Downsampling algorithms

Waveform display uses a min/max envelope. For output bin `b` among `B` bins and
`N` visible samples, its exact source interval is:

```text
start(b) = floor(b N / B)
end(b)   = floor((b + 1) N / B)
```

Both the minimum and maximum sample in that half-open interval are retained.
This costs `O(N)` time and `O(B)` output memory and cannot hide a local impulse
or trough the way point sampling can.

Correlation display uses the same exact partition, but keeps three facts per
bin: signed minimum, signed maximum, and the value/lag with greatest absolute
magnitude. Positive peaks, negative/inverted peaks, and the strongest candidate
therefore survive decimation.

The display budget is quantized to powers of two and limited to 64...4096 bins,
normally about two bins per horizontal pixel. Only the currently visible
source range is scanned after zooming. A bounded actor-isolated cache retains
the 12 most recent waveform/correlation viewport and resolution combinations.
Superseded preparation is cancelled.

All sample scanning and peak-detail preparation runs in detached user-initiated
tasks. Only publication of completed immutable render models occurs on the main
actor. A 30-minute file therefore does not create millions of SwiftUI points or
nodes; a plotted track remains at most 4096 envelope bins.

## Coordinates and interaction

`PlotViewport` owns full-domain and visible-domain bounds. Zoom preserves its
normalized anchor, pan clamps at the domain edges, and the minimum visible span
prevents degenerate views. Waveforms expose seconds and sample position;
correlation exposes signed lag samples and milliseconds. Positive lag follows
the correlation convention documented in `CorrelationAnalysis.md`: the
recording occurs after the reference.

Before alignment, the recording remains in its original sample coordinate
space and the estimated-delay marker is drawn at the measured lag. After
alignment, the recording plot offset is the negative fractional delay and the
marker moves to the common zero origin. Samples are not resynthesized or
mutated for this display operation.

## PNG and clipboard export

`PlotPNGExporter` renders light or dark PNGs with Core Graphics/Core Text and
ImageIO. Exports include a title, units, axes, signed data, and relevant markers.
Dimensions are validated in the 64...8192 pixel range. Rendering and encoding
run away from the main actor before the result is written or copied to the
pasteboard. Render models contain display titles but never source URLs, so
private file paths cannot be embedded in the image.

## Tested behavior and limits

Tests verify extrema preservation, signed correlation peak preservation,
sample/time transforms, bounded zoom and pan, empty and single-sample safety,
analysis-to-marker consistency, fractional alignment, requested PNG dimensions,
absence of source paths in encoded PNG data, background preparation, and a
one-million-sample input constrained to the render-bin budget.

Known limits:

- Full-range preparation is still `O(N)` in the visible samples. It is
  memory-bounded and asynchronous, but the first view of a very long file may
  require noticeable scanning time; persistent multi-resolution overview files
  are reserved for the storage phase.
- The cache is in-memory and intentionally bounded; it is not retained between
  launches.
- Peak interpolation visualization uses the same three-point parabola as the
  delay estimate. It is explanatory, not a higher-order reconstruction of the
  underlying analog correlation surface.
- PNG export is raster-only in this phase. PDF/SVG and print layout are not
  implemented.
- Accessibility exposes plot identity, controls, candidate buttons, and numeric
  diagnostic content. A keyboard-addressable data table for every rendered bin
  is intentionally omitted because the render bins are implementation detail.
