# Professional reports

`AudioLinkReporting` is the public export boundary for a run or session. The
schema is versioned independently from SQLite (`ReportSchemaVersion.v1`, wire
value `"1.0"`) and uses stable snake_case field names. Dates are ISO 8601 with
fractional seconds; every duration, delay, sample rate, drift and jitter field
has its unit in the field name or its CSV unit column.

## Privacy boundary

`ReportDocumentBuilder` copies only sanitized metadata. File names, format and
signal statistics are useful for reproducing an AV test, but absolute URLs,
home directories, security-scoped bookmarks, and raw audio are never placed in
a report. Device UID and file privacy identifiers are nullable and omitted by
default. `ReportPrivacyOptions(includeDetailedDiagnosticIdentifiers: true)` is
an explicit opt-in for support cases. The report model is not a database dump,
so future schema changes can preserve import compatibility.

## Formats

- JSON is the complete machine-readable `ReportDocument`; use
  `JSONCodec.decode` for a future report viewer.
- CSV writes `runs.csv` (one row per run), `session_summary.csv` when aggregate
  statistics exist, and `drift_observations.csv` when drift events exist.
  Values use an `en_US_POSIX` decimal point and RFC 4180-style escaping.
- HTML is self-contained, with inline CSS and SVG charts. Print styles remove
  dark-mode colors and avoid breaking a chart across pages.
- PDF is generated with PDFKit/Core Graphics, includes a project/date header,
  page numbers, wrapped diagnostic text and one page per chart.
- PNG exports the first selected chart at 1200×650 pixels. Use the existing
  result-page chart exporter for selecting a different chart.

All renderers check task cancellation and map file-system failures to
`ReportExportError`, so a caller can show a recoverable error instead of an
unexplained `NSError`. `Examples/SyntheticReport.json` is a small, non-personal
fixture suitable for documentation and Python ingestion examples.
