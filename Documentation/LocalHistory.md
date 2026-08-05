# Local measurement history

AudioLink Lab stores measurement history in a local SQLite database at
`Application Support/AudioLink Lab/History.sqlite`. SQLite is provided by the
Apple SDK and linked through the system `SQLite3` module. This avoids a network
dependency, keeps the storage boundary small, and gives the project direct
control over transactions, migrations, error mapping, and privacy-sensitive
columns.

The repository connection is owned by a Swift actor. SQLite is opened with
`FULLMUTEX`, foreign keys, a five-second busy timeout, and WAL journaling. Actor
isolation serializes application operations while WAL permits safe readers from
another process or repository connection.

## Schema v3

| Table | Purpose |
|---|---|
| `app_schema_version` | Explicit application schema version and migration timestamp. |
| `sessions` | Session identity, dates, name/notes, measurement/save types, app and algorithm versions, devices, legacy statistics, and optional repeated-run aggregate JSON. |
| `configurations` | Versioned opaque configuration payload plus searchable/comparable key-value summary. |
| `runs` | Run dates, quality, confidence, delay, sample rate, correlation/quality diagnostics, run statistics and notes. |
| `calibration_profiles` | Route-matched calibration profile blobs, fixed sample offset, method, confidence, date, notes and subtraction policy. |
| `files` | Role, random non-sensitive identifier, base file name, format and signal metrics, plus optional explicitly selected bookmark or relative managed-copy path. |
| `delay_estimates` | Canonical integer/fractional sample delay, sample rate, confidence and complete encoded estimate. |
| `quality_metrics` | One row per explainable metric, including normalized score, thresholds, weight and explanation. |
| `quality_issues` | Machine code, severity, user/technical explanations and recommended action. |
| `processing_steps` | Ordered, role-specific preprocessing operation and input/output frame counts. |
| `chart_cache_metadata` | Cache version, availability, signed correlation sequence metadata/blob, and waveform availability explanation. |

Foreign keys use `ON DELETE CASCADE`. Run date, quality and file-name indexes
support the History query path. Search text is parameter-bound and escapes SQL
`LIKE` wildcard characters.

Calibration profiles contain route descriptors but no raw audio or absolute file
paths. A run's `calibration_json` stores the profile ID and raw-versus-derived
result; the original delay row remains authoritative.

The correlation sequence is kept outside JSON as a versioned little-endian
Float32 blob. The associated first lag and sample count make the exact signed
sequence reconstructible for correlation and peak-detail plots without storing
raw audio. Quality, delay, diagnostics and configuration payloads use stable
Codable models.

## Privacy policy

The default policy is **results only**. It stores:

- base file names and random per-record file identifiers;
- audio format, frame count, duration, peak, RMS, clipping count and DC offset;
- explicit preprocessing configuration and log;
- delay, correlation, quality metrics/issues, diagnostics and statistics;
- creation time, app version and algorithm version;
- the signed correlation sequence required for correlation/peak inspection.

It does not store:

- absolute source paths or home-directory information;
- raw source or prepared audio;
- persistent file-access permission.

The repository rejects file names containing path separators, rejects absolute
or parent-relative managed paths, and rejects bookmarks/audio references on a
results-only record. JSON export inherits the same sanitized models.

The user can explicitly choose:

- **File access bookmarks**: saves security-scoped bookmarks, but no audio copy.
- **Audio copies**: copies both selected source files into the app container and
  stores only paths relative to that container. Deleting the run/session or
  clearing history deletes these managed copies; source files are untouched.
- **Do not save**: does not call the repository at all.

If copying succeeds but the database transaction fails, the persistence
coordinator removes the uncommitted copies. A history-save failure is presented
separately and never removes the completed analysis result from the UI.

## Sessions, runs and statistics

A session owns one frozen configuration and one or more runs. A normal file or
standalone real-time analysis creates one run. A repeated plan appends every
successful, failed, and warm-up step to the plan-ID session. Failed steps use an
explicit invalid-quality record without fake delay values.

`sessions.repeated_statistics_json` stores the selected aggregate and its
outlier method, threshold, marks, quality distribution, confidence interval,
and reliability label. Raw runs remain the authoritative source and marked
outliers are never deleted.

Statistics use the first valid run's sample rate as the canonical sample unit.
They include count, rounded mean/median/min/max delay, population standard
deviation expressed as seconds, and clock drift. Drift is the least-squares
slope of delay seconds against run time, multiplied by one million (ppm).

## Transactions and errors

Session replacement, bulk saving, multi-run append, multi-delete and clearing
use `BEGIN IMMEDIATE`, `COMMIT`, and `ROLLBACK`. Every child table is updated in
the same transaction. SQLite result codes map to structured
`MeasurementStorageError` values for open failure, corruption, migration,
constraint, encoding/decoding, transaction and query failures. Each error has a
short user-facing description and separate debug context.

The database is never automatically deleted or replaced when corruption is
detected. This preserves evidence for recovery and prevents a failed read from
silently destroying history.

## Migration design

SQLite `PRAGMA user_version` is the authoritative fast version check;
`app_schema_version` is the inspectable application record. Opening a new or
version-zero database creates schema v1, then applies additive v1→v2, v2→v3,
v3→v4 (device snapshots), and v4→v5 (opaque adaptive/spatial/distributed lab artifacts)
migrations in the same transaction. Existing v1 databases receive the nullable
`sessions.repeated_statistics_json` column. Version 3 adds nullable
`runs.calibration_json` and creates `calibration_profiles`; no table is rebuilt
or dropped. Both version markers move to 3 only after all alterations succeed.

Future migrations must be sequential and additive where practical:

1. read `user_version`;
2. reject a database newer than the running application;
3. begin one immediate transaction;
4. apply each missing migration in order without dropping user data;
5. update `app_schema_version` and `user_version` only after all steps succeed;
6. roll back every schema/data change on failure.

Tests verify that v0→v3 preserves a pre-existing legacy table, v1→v3 preserves
an existing session row, calibration profiles round-trip and delete safely,
repeated aggregates round-trip without changing raw runs, a forced child insert
failure rolls back the already inserted session, and corrupt input is reported
without changing its bytes.

## History and comparison UI

History sorts newest first and supports:

- file-name or note search;
- quality, device and measurement-type filters;
- bounded pagination;
- detail reopening and session name/note editing;
- individual and confirmed multi-run deletion;
- selected-run JSON export;
- confirmed clear-all;
- two-or-more-run comparison.

Comparison uses the first selected run as baseline and reports delay,
confidence, quality, configuration-key, sample-rate, preprocessing and device
differences. The models are independent from SwiftUI so a future chart-based
comparison can use the same data.

For a default results-only record, correlation and peak-detail data can be
reconstructed. The detail page explicitly states that waveforms cannot be
reconstructed because raw audio was not retained. With the explicit audio-copy
policy, managed sources remain available for a future asynchronous re-import
path; this phase reports that availability but does not silently decode them.

## Validation

Repository tests cover empty creation, schema tables, complete encoding/decoding,
second-connection reopening, update/delete, SQL transaction rollback, migration,
corruption, concurrent writes, 125-record pagination/filtering, privacy
validation, multi-run statistics and comparison. App tests cover automatic
results-only saving, do-not-save, independent save failure, security-scoped
bookmarks, managed audio copying/deletion, History search/update/filter,
comparison, export and multi-delete.
