# Repeated measurements and statistics

Repeated real-time measurement freezes one `AudioRouteConfiguration` and one
signal/correlation configuration, executes warm-up plus measured runs, stores
every outcome in one history session, and calculates an inspectable aggregate.
It does not merge results recorded under a changed input, output, nominal sample
rate, channel, or buffer configuration.

## Public model and control boundary

`AudioLinkRealtime` exposes `MeasurementPlan`, `RandomSeedPolicy`, `RunOutcome`,
`RepeatedMeasurementReport`, `RunScheduler`, `RepeatedMeasurementController`,
`StatisticalAnalyzer`, and `OutlierDetector`. Its state is `preparing`,
`warmingUp`, `running`, `paused`, `cancelling`, `completed`, or `failed`.
Mockable runner, scheduler, device, and progress-saving protocols keep hardware,
timing, persistence, and UI out of the algorithm.

`AudioLinkCore` owns the Codable aggregate models so Storage can persist them
without importing the real-time package or SwiftUI. The app owns only state
projection, native Canvas rendering, and repository composition.

## Plan and state behavior

A plan accepts 1–1000 measured runs plus 0–100 warm-ups. The app offers quick
choices for 5, 20, and 100 runs. It also fixes interval, pre/post-roll, signal
kind, deterministic seed policy, whether warm-ups enter statistics, consecutive
failure policy, and outlier policy.

Before the plan and before every scheduled step, the controller revalidates the
frozen route. Pause stops the active single-run engine. Resume revalidates the
same route and retries an interrupted step rather than recording it as a failed
measurement. A route change aborts the plan; it never silently starts a new
population. Cancellation safely stops the engine and leaves already completed
runs stored and reviewable.

Progress reports scheduled/completed/success/failed/remaining step counts and
the latest valid delay. It intentionally does not invent a precise ETA because
permission, driver, capture, DSP, and storage time may differ between runs.

## Statistical definitions

All aggregate values are calculated from successful, non-discarded observations
in milliseconds. Failed runs remain in `outcomeCount` and `failureCount` but do
not enter the numeric delay population.

For selected delays `x[1...n]`:

- mean is `sum(x) / n`;
- variance is sample variance `sum((x - mean)^2) / (n - 1)`, in ms²;
- **jitter** is explicitly the sample standard deviation `sqrt(variance)`, in ms;
- peak-to-peak jitter is `max(x) - min(x)`;
- P50/P90/P95/P99 use Hyndman–Fan type 7 linear interpolation, matching NumPy/R;
- MAD is `median(abs(x - median(x)))` and IQR is `P75 - P25`;
- the mean confidence interval is a two-sided 95% Student-t interval
  `mean ± t(0.975,n-1) × s/sqrt(n)`.

The interval assumes independent observations from an approximately stationary
population. Audio runs can be autocorrelated, drifting, or multimodal, so it is
labeled with its method and is not a hardware guarantee.

Reliability labels are empirical communication guardrails: 0–4 selected samples
are `insufficient`, 5–19 `preliminary`, 20–49 `moderate`, and 50+ `strong`. An
interval is not emitted for fewer than two selected observations.

## Outliers

Two robust methods are implemented:

- scaled MAD: `abs(x - median) / (1.4826 × MAD) > threshold`, default 3.5;
- IQR fences: outside `[Q1 - k×IQR, Q3 + k×IQR]`, conventionally k=1.5.

Detection requires at least four successful observations. When robust scale is
zero, a differing value receives a finite maximum score so JSON remains valid.
Outliers retain run ID, index, value, method, threshold, score, and explanation.
They are never deleted. Users may switch between aggregates that include or
exclude marked observations; the raw run and failure lists do not change.

## Visualization and performance

The result UI uses SwiftUI `Canvas`, not per-sample Shapes or a chart dependency:
delay over index (warm-ups muted, failures crossed, outliers ringed), a bounded
histogram of at most 30 bins, a five-number box plot, and quality over index.
Render preparation caps a validated plan at 1000 points and Canvas draws one
node per plot. Statistics and orchestration run outside the main actor; only
immutable snapshots cross into the view model.

## Automated coverage and limits

Tests cover exact statistics and percentile edges, empty/single/equal samples,
multiple outliers, include/exclude, failure exclusion, quality distribution,
warm-up discard, repeated-failure stop, pause/resume retry, cancellation, route
change, persistence round-trip, v1→v2 migration, and plot-data bounds.

Real hardware still needs long-run testing for driver reset, temperature,
independent clocks, sleep/wake, acoustic movement, and feedback safety. The
aggregate reports observed correlation delay; it does not compensate for
undocumented hardware latency or claim successive runs are independent.
