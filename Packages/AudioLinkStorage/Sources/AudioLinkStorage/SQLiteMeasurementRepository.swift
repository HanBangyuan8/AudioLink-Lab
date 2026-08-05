import AudioLinkCore
import Foundation
import SQLite3

public actor SQLiteMeasurementRepository: MeasurementRepository {
    public static let currentSchemaVersion = AudioLinkReleaseMetadata.databaseSchemaVersion

    private let databaseURL: URL
    private let isInMemory: Bool
    private let connection: SQLiteConnection
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var database: OpaquePointer { connection.pointer }

    public init(
        databaseURL: URL,
        createParentDirectories: Bool = true,
        inMemory: Bool = false
    ) throws {
        if createParentDirectories, !inMemory, !databaseURL.path.isEmpty {
            do {
                try FileManager.default.createDirectory(
                    at: databaseURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw MeasurementStorageError.unableToOpenDatabase(message: error.localizedDescription)
            }
        }

        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            inMemory ? ":memory:" : databaseURL.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "SQLite returned code \(result)."
            if let opened { sqlite3_close_v2(opened) }
            throw MeasurementStorageError.unableToOpenDatabase(message: message)
        }

        self.databaseURL = databaseURL
        self.isInMemory = inMemory
        self.connection = SQLiteConnection(pointer: opened)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()

        do {
            try Self.execute("PRAGMA foreign_keys = ON", on: opened)
            try Self.execute("PRAGMA busy_timeout = 5000", on: opened)
            try Self.execute("PRAGMA journal_mode = WAL", on: opened)
            let schemaBeforeMigration = try Self.scalarInt("PRAGMA user_version", database: opened)
            if schemaBeforeMigration < Self.currentSchemaVersion, !inMemory {
                do {
                    try Self.createMigrationBackup(
                        databaseURL: databaseURL,
                        database: opened,
                        fromVersion: schemaBeforeMigration
                    )
                } catch {
                    throw MeasurementStorageError.migrationFailed(
                        fromVersion: schemaBeforeMigration,
                        toVersion: Self.currentSchemaVersion,
                        message: "The pre-migration backup could not be created. The database was left untouched."
                    )
                }
            }
            try Self.migrateIfNeeded(database: opened)
            try Self.execute("PRAGMA quick_check", on: opened)
        } catch let error as MeasurementStorageError {
            throw error
        } catch {
            throw MeasurementStorageError.corruptDatabase(message: error.localizedDescription)
        }
    }

    public func saveSession(_ session: MeasurementHistorySession) throws {
        guard session.savePolicy != .doNotSave else { return }
        try validate(session)
        try transaction {
            try store(session)
        }
    }

    public func saveSessions(_ sessions: [MeasurementHistorySession]) throws {
        let storedSessions = sessions.filter { $0.savePolicy != .doNotSave }
        for session in storedSessions { try validate(session) }
        try transaction {
            for session in storedSessions { try store(session) }
        }
    }

    public func appendRun(_ run: MeasurementHistoryRun, toSession sessionID: UUID) throws {
        guard run.sessionID == sessionID else {
            throw MeasurementStorageError.invalidRecord(message: "Run session ID does not match the append target.")
        }
        guard let existing = try session(id: sessionID) else {
            throw MeasurementStorageError.recordNotFound(kind: "session", id: sessionID)
        }
        guard !existing.runs.contains(where: { $0.id == run.id }) else {
            throw MeasurementStorageError.constraintViolation(message: "Run already exists in this session.")
        }
        let runs = existing.runs + [run]
        let updated = MeasurementHistorySession(
            id: existing.id,
            createdAt: existing.createdAt,
            updatedAt: Date(),
            name: existing.name,
            notes: existing.notes,
            measurementType: existing.measurementType,
            savePolicy: existing.savePolicy,
            configurationPayload: existing.configurationPayload,
            configurationSummary: existing.configurationSummary,
            statistics: MeasurementHistoryStatisticsCalculator().statistics(for: runs),
            repeatedStatistics: existing.repeatedStatistics,
            inputDevice: existing.inputDevice,
            outputDevice: existing.outputDevice,
            appVersion: existing.appVersion,
            algorithmVersion: existing.algorithmVersion,
            runs: runs
        )
        try validate(updated)
        try transaction {
            try store(run)
            let statement = try prepare(
                "UPDATE sessions SET updated_at = ?, statistics_json = ? WHERE id = ?",
                values: [
                    .real(updated.updatedAt.timeIntervalSince1970),
                    optionalBlob(try encodeOptional(updated.statistics)),
                    .text(sessionID.uuidString)
                ]
            )
            try statement.stepDone()
        }
    }

    public func updateRepeatedStatistics(
        sessionID: UUID,
        statistics: RepeatedMeasurementStatistics?,
        configurationPayload: Data,
        configurationSummary: [String: String],
        updatedAt: Date
    ) throws {
        guard !configurationPayload.isEmpty else {
            throw MeasurementStorageError.invalidRecord(message: "Configuration payload cannot be empty.")
        }
        let existence = try prepare(
            "SELECT 1 FROM sessions WHERE id = ?",
            values: [.text(sessionID.uuidString)]
        )
        guard try existence.stepRow() else {
            throw MeasurementStorageError.recordNotFound(kind: "session", id: sessionID)
        }
        try transaction {
            let sessionUpdate = try prepare(
                "UPDATE sessions SET updated_at = ?, repeated_statistics_json = ? WHERE id = ?",
                values: [
                    .real(updatedAt.timeIntervalSince1970),
                    optionalBlob(try encodeOptional(statistics)),
                    .text(sessionID.uuidString)
                ]
            )
            try sessionUpdate.stepDone()
            let configurationUpdate = try prepare(
                "UPDATE configurations SET payload = ?, summary_json = ? WHERE session_id = ?",
                values: [
                    .blob(configurationPayload),
                    .blob(try encode(configurationSummary)),
                    .text(sessionID.uuidString)
                ]
            )
            try configurationUpdate.stepDone()
        }
    }

    public func session(id: UUID) throws -> MeasurementHistorySession? {
        let statement = try prepare(
            """
            SELECT created_at, updated_at, name, notes, measurement_type, save_policy,
                   app_version, algorithm_version, input_device_json, output_device_json,
                   statistics_json, repeated_statistics_json
            FROM sessions WHERE id = ?
            """,
            values: [.text(id.uuidString)]
        )
        guard try statement.stepRow() else { return nil }
        let createdAt = Date(timeIntervalSince1970: statement.double(0))
        let updatedAt = Date(timeIntervalSince1970: statement.double(1))
        let name = statement.text(2)
        let notes = statement.text(3)
        guard let type = StoredMeasurementType(rawValue: statement.text(4)),
              let policy = MeasurementSavePolicy(rawValue: statement.text(5)) else {
            throw MeasurementStorageError.decodingFailed(type: "MeasurementHistorySession", message: "Unknown enum value.")
        }
        let appVersion = statement.text(6)
        let algorithmVersion = statement.text(7)
        let inputDevice: DeviceDescriptor? = try decodeOptional(DeviceDescriptor.self, data: statement.data(8))
        let outputDevice: DeviceDescriptor? = try decodeOptional(DeviceDescriptor.self, data: statement.data(9))
        let statistics: MeasurementStatistics? = try decodeOptional(MeasurementStatistics.self, data: statement.data(10))
        let repeatedStatistics: RepeatedMeasurementStatistics? = try decodeOptional(
            RepeatedMeasurementStatistics.self,
            data: statement.data(11)
        )

        let configurationStatement = try prepare(
            "SELECT payload, summary_json FROM configurations WHERE session_id = ?",
            values: [.text(id.uuidString)]
        )
        guard try configurationStatement.stepRow(), let payload = configurationStatement.data(0) else {
            throw MeasurementStorageError.decodingFailed(type: "configuration", message: "Configuration row is missing.")
        }
        let summary = try decode([String: String].self, data: configurationStatement.requiredData(1))
        return MeasurementHistorySession(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            name: name,
            notes: notes,
            measurementType: type,
            savePolicy: policy,
            configurationPayload: payload,
            configurationSummary: summary,
            statistics: statistics,
            repeatedStatistics: repeatedStatistics,
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            appVersion: appVersion,
            algorithmVersion: algorithmVersion,
            runs: try loadRuns(sessionID: id)
        )
    }

    public func run(id: UUID) throws -> MeasurementHistoryRun? {
        let statement = try prepare("SELECT session_id FROM runs WHERE id = ?", values: [.text(id.uuidString)])
        guard try statement.stepRow(), let sessionID = UUID(uuidString: statement.text(0)) else { return nil }
        return try loadRuns(sessionID: sessionID).first { $0.id == id }
    }

    public func runs(matching query: MeasurementHistoryQuery) throws -> MeasurementHistoryPage {
        let predicate = runQueryPredicate(query)
        let countStatement = try prepare(
            """
            SELECT COUNT(DISTINCT r.id)
            FROM runs r
            JOIN sessions s ON s.id = r.session_id
            JOIN files rf ON rf.run_id = r.id AND rf.role = 'reference'
            JOIN files ofile ON ofile.run_id = r.id AND ofile.role = 'recording'
            \(predicate.sql)
            """,
            values: predicate.values
        )
        guard try countStatement.stepRow() else {
            throw MeasurementStorageError.queryFailed(operation: "count runs", message: "No count row returned.")
        }
        let totalCount = countStatement.int(0)
        var values = predicate.values
        values.append(.integer(Int64(query.pageSize)))
        values.append(.integer(Int64(query.offset)))
        let statement = try prepare(
            """
            SELECT r.id, r.session_id, s.name, r.created_at, s.measurement_type,
                   rf.file_name, ofile.file_name, r.delay_ms, r.sample_rate_hz,
                   r.quality_level, r.confidence, s.input_device_name,
                   s.output_device_name, r.notes
            FROM runs r
            JOIN sessions s ON s.id = r.session_id
            JOIN files rf ON rf.run_id = r.id AND rf.role = 'reference'
            JOIN files ofile ON ofile.run_id = r.id AND ofile.role = 'recording'
            \(predicate.sql)
            ORDER BY r.created_at DESC, r.id ASC
            LIMIT ? OFFSET ?
            """,
            values: values
        )
        var summaries: [MeasurementHistoryRunSummary] = []
        while try statement.stepRow() {
            summaries.append(try decodeSummary(statement))
        }
        return MeasurementHistoryPage(
            runs: summaries,
            totalCount: totalCount,
            offset: query.offset,
            pageSize: query.pageSize
        )
    }

    public func updateSession(id: UUID, name: String, notes: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MeasurementStorageError.invalidRecord(message: "Session name cannot be empty.")
        }
        let statement = try prepare(
            "UPDATE sessions SET name = ?, notes = ?, updated_at = ? WHERE id = ?",
            values: [.text(trimmedName), .text(notes), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
        try statement.stepDone()
        guard sqlite3_changes(database) > 0 else {
            throw MeasurementStorageError.recordNotFound(kind: "session", id: id)
        }
    }

    public func deleteRun(id: UUID) throws {
        let paths = try managedCopyPaths(
            sql: "SELECT audio_copy_relative_path FROM files WHERE run_id = ? AND audio_copy_relative_path IS NOT NULL",
            values: [.text(id.uuidString)]
        )
        let statement = try prepare("DELETE FROM runs WHERE id = ?", values: [.text(id.uuidString)])
        try statement.stepDone()
        try removeManagedAudioCopies(paths)
    }

    public func deleteRuns(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let uniqueIDs = Array(Set(ids))
        var paths: [String] = []
        for id in uniqueIDs {
            paths.append(contentsOf: try managedCopyPaths(
                sql: "SELECT audio_copy_relative_path FROM files WHERE run_id = ? AND audio_copy_relative_path IS NOT NULL",
                values: [.text(id.uuidString)]
            ))
        }
        try transaction {
            for id in uniqueIDs {
                let statement = try prepare("DELETE FROM runs WHERE id = ?", values: [.text(id.uuidString)])
                try statement.stepDone()
            }
        }
        try removeManagedAudioCopies(paths)
    }

    public func deleteSession(id: UUID) throws {
        let paths = try managedCopyPaths(
            sql: """
            SELECT f.audio_copy_relative_path FROM files f
            JOIN runs r ON r.id = f.run_id
            WHERE r.session_id = ? AND f.audio_copy_relative_path IS NOT NULL
            """,
            values: [.text(id.uuidString)]
        )
        let statement = try prepare("DELETE FROM sessions WHERE id = ?", values: [.text(id.uuidString)])
        try statement.stepDone()
        try removeManagedAudioCopies(paths)
    }

    public func deleteAll() throws {
        let paths = try managedCopyPaths(
            sql: "SELECT audio_copy_relative_path FROM files WHERE audio_copy_relative_path IS NOT NULL"
        )
        try transaction {
            try Self.execute("DELETE FROM sessions", on: database)
        }
        try removeManagedAudioCopies(paths)
    }

    public func comparison(runIDs: [UUID]) throws -> MeasurementRunComparison {
        let uniqueIDs = runIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard uniqueIDs.count >= 2 else {
            throw MeasurementStorageError.invalidRecord(message: "At least two unique runs are required for comparison.")
        }
        var pairs: [(MeasurementHistorySession, MeasurementHistoryRun, MeasurementHistoryRunSummary)] = []
        for id in uniqueIDs {
            guard let run = try run(id: id), let session = try session(id: run.sessionID) else {
                throw MeasurementStorageError.recordNotFound(kind: "run", id: id)
            }
            pairs.append((session, run, summary(session: session, run: run)))
        }
        let baseline = pairs[0]
        let baselineSteps = baseline.1.processingSteps.map(\.summary)
        let baselineDevices = [baseline.0.inputDevice?.id, baseline.0.outputDevice?.id]
        let entries = pairs.map { session, run, summary in
            let configurationKeys = Set(baseline.0.configurationSummary.keys).union(session.configurationSummary.keys)
            let configDifferences = configurationKeys.sorted().filter {
                baseline.0.configurationSummary[$0] != session.configurationSummary[$0]
            }
            let currentSteps = run.processingSteps.map(\.summary)
            let stepDifference = Array(Set(baselineSteps).symmetricDifference(Set(currentSteps))).sorted()
            let delayDifference: Double?
            if let baselineDelay = baseline.1.delayEstimate?.fractionalMilliseconds,
               let currentDelay = run.delayEstimate?.fractionalMilliseconds {
                delayDifference = currentDelay - baselineDelay
            } else {
                delayDifference = nil
            }
            return MeasurementRunComparisonEntry(
                id: run.id,
                summary: summary,
                delayDifferenceMilliseconds: delayDifference,
                confidenceDifference: run.quality.confidence.value - baseline.1.quality.confidence.value,
                qualityLevelDifference: "\(baseline.1.quality.level.rawValue) → \(run.quality.level.rawValue)",
                configurationDifferences: configDifferences,
                sampleRateDifferenceHertz: summary.sampleRateHertz - baseline.2.sampleRateHertz,
                preprocessingDifferences: stepDifference,
                deviceDifference: baselineDevices != [session.inputDevice?.id, session.outputDevice?.id]
            )
        }
        return MeasurementRunComparison(baselineRunID: baseline.1.id, entries: entries)
    }

    public func repositoryInfo() throws -> MeasurementRepositoryInfo {
        let sessionCount = try scalarInt("SELECT COUNT(*) FROM sessions")
        let runCount = try scalarInt("SELECT COUNT(*) FROM runs")
        let size: Int64
        if isInMemory {
            size = 0
        } else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
            size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return MeasurementRepositoryInfo(
            schemaVersion: Self.currentSchemaVersion,
            databaseSizeBytes: size,
            sessionCount: sessionCount,
            runCount: runCount
        )
    }

    public func saveCalibrationProfile(_ profile: CalibrationProfile) throws {
        try profile.validate()
        let statement = try prepare(
            """
            INSERT INTO calibration_profiles (
                id, profile_name, input_device_json, output_device_json,
                channel_mapping_json, sample_rate_hz, buffer_frame_count,
                known_fixed_delay_samples, confidence, calibration_method,
                measurement_date, notes, subtract_offset_by_default
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                profile_name=excluded.profile_name, input_device_json=excluded.input_device_json,
                output_device_json=excluded.output_device_json, channel_mapping_json=excluded.channel_mapping_json,
                sample_rate_hz=excluded.sample_rate_hz, buffer_frame_count=excluded.buffer_frame_count,
                known_fixed_delay_samples=excluded.known_fixed_delay_samples, confidence=excluded.confidence,
                calibration_method=excluded.calibration_method, measurement_date=excluded.measurement_date,
                notes=excluded.notes, subtract_offset_by_default=excluded.subtract_offset_by_default
            """,
            values: [
                .text(profile.id.uuidString), .text(profile.profileName),
                .blob(try encode(profile.inputDevice)), .blob(try encode(profile.outputDevice)),
                .blob(try encode(profile.channelMapping)), .real(profile.sampleRate.hertz),
                .integer(Int64(profile.bufferFrameCount)), .integer(profile.knownFixedDelay.sampleCount.rawValue),
                .real(profile.confidence), .text(profile.calibrationMethod.rawValue),
                // Preserve the exact Foundation Date bit pattern. SQLite REAL
                // conversion can round the sub-microsecond bits of a Date, and
                // a REAL-affinity column would coerce an integer bit pattern.
                .blob(Self.exactDateData(profile.measurementDate)), .text(profile.notes),
                .integer(profile.subtractOffsetByDefault ? 1 : 0)
            ]
        )
        try transaction { try statement.stepDone() }
    }

    public func calibrationProfiles() throws -> [CalibrationProfile] {
        let statement = try prepare(
            """
            SELECT id, profile_name, input_device_json, output_device_json,
                   channel_mapping_json, sample_rate_hz, buffer_frame_count,
                   known_fixed_delay_samples, confidence, calibration_method,
                   measurement_date, notes, subtract_offset_by_default
            FROM calibration_profiles ORDER BY measurement_date DESC, id ASC
            """
        )
        var profiles: [CalibrationProfile] = []
        while try statement.stepRow() {
            guard let id = UUID(uuidString: statement.text(0)),
                  let method = CalibrationMethod(rawValue: statement.text(9)) else {
                throw MeasurementStorageError.decodingFailed(type: "calibration profile", message: "Invalid profile identity or method.")
            }
            let sampleRate = try SampleRate(hertz: statement.double(5))
            profiles.append(CalibrationProfile(
                id: id,
                profileName: statement.text(1),
                inputDevice: try decode(DeviceDescriptor.self, data: statement.requiredData(2)),
                outputDevice: try decode(DeviceDescriptor.self, data: statement.requiredData(3)),
                channelMapping: try decode(CalibrationChannelMapping.self, data: statement.requiredData(4)),
                sampleRate: sampleRate,
                bufferFrameCount: statement.int(6),
                knownFixedDelay: CalibrationOffset(sampleCount: SampleCount(rawValue: statement.int64(7)), sampleRate: sampleRate),
                measurementDate: Date(timeIntervalSince1970: statement.dateIntervalSince1970(10)),
                notes: statement.text(11),
                confidence: statement.double(8),
                calibrationMethod: method,
                subtractOffsetByDefault: statement.bool(12)
            ))
        }
        return profiles
    }

    public func calibrationProfile(id: UUID) throws -> CalibrationProfile? {
        try calibrationProfiles().first { $0.id == id }
    }

    public func deleteCalibrationProfile(id: UUID) throws {
        let statement = try prepare("DELETE FROM calibration_profiles WHERE id = ?", values: [.text(id.uuidString)])
        try transaction { try statement.stepDone() }
    }

    public func saveDeviceSnapshot(_ snapshot: DeviceSnapshotRecord) throws {
        guard !snapshot.identity.isEmpty, !snapshot.name.isEmpty else {
            throw MeasurementStorageError.invalidRecord(message: "Device snapshot identity and name cannot be empty.")
        }
        let statement = try prepare(
            """
            INSERT INTO device_snapshots(id, identity, captured_at, name, manufacturer, transport, payload, anonymized)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET identity=excluded.identity, captured_at=excluded.captured_at,
            name=excluded.name, manufacturer=excluded.manufacturer, transport=excluded.transport,
            payload=excluded.payload, anonymized=excluded.anonymized
            """,
            values: [.text(snapshot.id.uuidString), .text(snapshot.identity), .blob(Self.exactDateData(snapshot.capturedAt)), .text(snapshot.name), optionalText(snapshot.manufacturer), .text(snapshot.transport), .blob(snapshot.payload), .integer(snapshot.isAnonymized ? 1 : 0)]
        )
        try transaction { try statement.stepDone() }
    }

    public func deviceSnapshots(identity: String? = nil) throws -> [DeviceSnapshotRecord] {
        let statement = try prepare(
            "SELECT id, identity, captured_at, name, manufacturer, transport, payload, anonymized FROM device_snapshots WHERE (? IS NULL OR identity = ?) ORDER BY captured_at DESC",
            values: [optionalText(identity), optionalText(identity)]
        )
        var snapshots: [DeviceSnapshotRecord] = []
        while try statement.stepRow() {
            guard let id = UUID(uuidString: statement.text(0)) else { throw MeasurementStorageError.decodingFailed(type: "device snapshot", message: "Invalid snapshot ID.") }
            snapshots.append(DeviceSnapshotRecord(id: id, identity: statement.text(1), capturedAt: Date(timeIntervalSince1970: statement.dateIntervalSince1970(2)), name: statement.text(3), manufacturer: statement.optionalText(4), transport: statement.text(5), payload: try statement.requiredData(6), isAnonymized: statement.bool(7)))
        }
        return snapshots
    }

    public func deleteDeviceSnapshot(id: UUID) throws {
        let statement = try prepare("DELETE FROM device_snapshots WHERE id = ?", values: [.text(id.uuidString)])
        try transaction { try statement.stepDone() }
    }

    public func saveLabArtifact(_ artifact: LabArtifactRecord) throws {
        guard !artifact.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !artifact.payload.isEmpty else {
            throw MeasurementStorageError.invalidRecord(message: "Lab artifact kind and payload cannot be empty.")
        }
        let statement = try prepare(
            """
            INSERT INTO lab_artifacts(id, kind, created_at, updated_at, payload, anonymized)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, created_at=excluded.created_at,
            updated_at=excluded.updated_at, payload=excluded.payload, anonymized=excluded.anonymized
            """,
            values: [.text(artifact.id.uuidString), .text(artifact.kind), .blob(Self.exactReferenceDateData(artifact.createdAt)), .blob(Self.exactReferenceDateData(artifact.updatedAt)), .blob(artifact.payload), .integer(artifact.isAnonymized ? 1 : 0)]
        )
        try transaction { try statement.stepDone() }
    }

    public func labArtifacts(kind: String? = nil) throws -> [LabArtifactRecord] {
        let statement = try prepare(
            "SELECT id, kind, created_at, updated_at, payload, anonymized FROM lab_artifacts WHERE (? IS NULL OR kind = ?) ORDER BY updated_at DESC",
            values: [optionalText(kind), optionalText(kind)]
        )
        var records: [LabArtifactRecord] = []
        while try statement.stepRow() {
            guard let id = UUID(uuidString: statement.text(0)) else { throw MeasurementStorageError.decodingFailed(type: "lab artifact", message: "Invalid artifact ID.") }
            records.append(LabArtifactRecord(id: id, kind: statement.text(1), createdAt: statement.referenceDate(2), updatedAt: statement.referenceDate(3), payload: try statement.requiredData(4), isAnonymized: statement.bool(5)))
        }
        return records
    }

    public func deleteLabArtifact(id: UUID) throws {
        let statement = try prepare("DELETE FROM lab_artifacts WHERE id = ?", values: [.text(id.uuidString)])
        try transaction { try statement.stepDone() }
    }

    private func store(_ session: MeasurementHistorySession) throws {
        let inputJSON = try encodeOptional(session.inputDevice)
        let outputJSON = try encodeOptional(session.outputDevice)
        let statisticsJSON = try encodeOptional(session.statistics)
        let repeatedStatisticsJSON = try encodeOptional(session.repeatedStatistics)
        let statement = try prepare(
            """
            INSERT INTO sessions (
                id, created_at, updated_at, name, notes, measurement_type, save_policy,
                app_version, algorithm_version, input_device_id, input_device_name,
                output_device_id, output_device_name, input_device_json, output_device_json,
                statistics_json, repeated_statistics_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                updated_at=excluded.updated_at, name=excluded.name, notes=excluded.notes,
                measurement_type=excluded.measurement_type, save_policy=excluded.save_policy,
                app_version=excluded.app_version, algorithm_version=excluded.algorithm_version,
                input_device_id=excluded.input_device_id, input_device_name=excluded.input_device_name,
                output_device_id=excluded.output_device_id, output_device_name=excluded.output_device_name,
                input_device_json=excluded.input_device_json, output_device_json=excluded.output_device_json,
                statistics_json=excluded.statistics_json,
                repeated_statistics_json=excluded.repeated_statistics_json
            """,
            values: [
                .text(session.id.uuidString), .real(session.createdAt.timeIntervalSince1970),
                .real(session.updatedAt.timeIntervalSince1970), .text(session.name), .text(session.notes),
                .text(session.measurementType.rawValue), .text(session.savePolicy.rawValue),
                .text(session.appVersion), .text(session.algorithmVersion),
                optionalText(session.inputDevice?.id), optionalText(session.inputDevice?.name),
                optionalText(session.outputDevice?.id), optionalText(session.outputDevice?.name),
                optionalBlob(inputJSON), optionalBlob(outputJSON), optionalBlob(statisticsJSON),
                optionalBlob(repeatedStatisticsJSON)
            ]
        )
        try statement.stepDone()

        let configuration = try prepare(
            """
            INSERT INTO configurations(session_id, payload, summary_json) VALUES (?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET payload=excluded.payload, summary_json=excluded.summary_json
            """,
            values: [
                .text(session.id.uuidString), .blob(session.configurationPayload),
                .blob(try encode(session.configurationSummary))
            ]
        )
        try configuration.stepDone()

        let incomingRunIDs = Set(session.runs.map { $0.id.uuidString })
        let existing = try prepare("SELECT id FROM runs WHERE session_id = ?", values: [.text(session.id.uuidString)])
        var removedIDs: [String] = []
        while try existing.stepRow() {
            let id = existing.text(0)
            if !incomingRunIDs.contains(id) { removedIDs.append(id) }
        }
        for id in removedIDs {
            let deletion = try prepare("DELETE FROM runs WHERE id = ?", values: [.text(id)])
            try deletion.stepDone()
        }
        for run in session.runs { try store(run) }
    }

    private func store(_ run: MeasurementHistoryRun) throws {
        let correlationWithoutSequence = run.correlation.map {
            CorrelationResult(
                peakOffset: $0.peakOffset,
                normalizedPeak: $0.normalizedPeak,
                peakToSidelobeRatio: $0.peakToSidelobeRatio,
                confidence: $0.confidence,
                primaryPeak: $0.primaryPeak,
                secondaryPeak: $0.secondaryPeak,
                sequence: nil,
                diagnostics: $0.diagnostics
            )
        }
        let statement = try prepare(
            """
            INSERT INTO runs (
                id, session_id, created_at, completed_at, quality_level, confidence,
                delay_ms, sample_rate_hz, correlation_json, quality_json, statistics_json, notes, calibration_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                session_id=excluded.session_id, created_at=excluded.created_at,
                completed_at=excluded.completed_at, quality_level=excluded.quality_level,
                confidence=excluded.confidence, delay_ms=excluded.delay_ms,
                sample_rate_hz=excluded.sample_rate_hz, correlation_json=excluded.correlation_json,
                quality_json=excluded.quality_json, statistics_json=excluded.statistics_json,
                notes=excluded.notes, calibration_json=excluded.calibration_json
            """,
            values: [
                .text(run.id.uuidString), .text(run.sessionID.uuidString),
                .real(run.createdAt.timeIntervalSince1970), optionalReal(run.completedAt?.timeIntervalSince1970),
                .text(run.quality.level.rawValue), .real(run.quality.confidence.value),
                optionalReal(run.delayEstimate?.fractionalMilliseconds),
                .real(run.delayEstimate?.sampleRate.hertz ?? run.referenceFile.format.sampleRate.hertz),
                optionalBlob(try encodeOptional(correlationWithoutSequence)), .blob(try encode(run.quality)),
                optionalBlob(try encodeOptional(run.statistics)), .text(run.notes),
                optionalBlob(try encodeOptional(run.calibration))
            ]
        )
        try statement.stepDone()
        try replaceDelay(run)
        try replaceFiles(run)
        try replaceQualityRows(run)
        try replaceProcessingSteps(run)
        try replaceChartCache(run)
    }

    private func replaceDelay(_ run: MeasurementHistoryRun) throws {
        let deletion = try prepare("DELETE FROM delay_estimates WHERE run_id = ?", values: [.text(run.id.uuidString)])
        try deletion.stepDone()
        guard let delay = run.delayEstimate else { return }
        let insertion = try prepare(
            """
            INSERT INTO delay_estimates(
                run_id, sample_offset, fractional_sample_offset, sample_rate_hz,
                confidence, peak_amplitude, peak_to_sidelobe_ratio, is_reliable, payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(run.id.uuidString), .integer(delay.sampleOffset.rawValue),
                optionalReal(delay.fractionalSampleOffset), .real(delay.sampleRate.hertz),
                .real(delay.confidence), optionalReal(delay.peakAmplitude),
                optionalReal(delay.peakToSidelobeRatio), optionalBool(delay.isReliable),
                .blob(try encode(delay))
            ]
        )
        try insertion.stepDone()
    }

    private func replaceFiles(_ run: MeasurementHistoryRun) throws {
        let deletion = try prepare("DELETE FROM files WHERE run_id = ?", values: [.text(run.id.uuidString)])
        try deletion.stepDone()
        for file in [run.referenceFile, run.recordingFile] {
            let statement = try prepare(
                """
                INSERT INTO files(
                    id, run_id, role, privacy_identifier, file_name, container, encoding,
                    format_json, frame_count, duration_seconds, peak_magnitude, rms,
                    clipping_count, dc_offset, bookmark_blob, audio_copy_relative_path
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                values: [
                    .text(file.id.uuidString), .text(run.id.uuidString), .text(file.role.rawValue),
                    .text(file.privacyIdentifier), .text(file.fileName), .text(file.container),
                    .text(file.encoding), .blob(try encode(file.format)), .integer(Int64(file.frameCount)),
                    .real(file.durationSeconds), .real(file.peakMagnitude), .real(file.rootMeanSquare),
                    .integer(Int64(file.clippingSampleCount)), .real(file.dcOffset),
                    optionalBlob(file.securityScopedBookmark), optionalText(file.audioCopyRelativePath)
                ]
            )
            try statement.stepDone()
        }
    }

    private func replaceQualityRows(_ run: MeasurementHistoryRun) throws {
        for table in ["quality_metrics", "quality_issues"] {
            let deletion = try prepare("DELETE FROM \(table) WHERE run_id = ?", values: [.text(run.id.uuidString)])
            try deletion.stepDone()
        }
        for metric in run.quality.metrics {
            let statement = try prepare(
                """
                INSERT INTO quality_metrics(
                    run_id, code, value, unit, normalized_score, weight,
                    ideal_minimum, ideal_maximum, explanation, payload
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                values: [
                    .text(run.id.uuidString), .text(metric.code.rawValue), .real(metric.value),
                    .text(metric.unit.rawValue), .real(metric.normalizedScore), .real(metric.weight),
                    optionalReal(metric.idealMinimum), optionalReal(metric.idealMaximum),
                    .text(metric.explanation), .blob(try encode(metric))
                ]
            )
            try statement.stepDone()
        }
        for issue in run.quality.issues {
            let statement = try prepare(
                """
                INSERT INTO quality_issues(
                    run_id, code, severity, user_description, technical_description,
                    recommended_action, payload
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                values: [
                    .text(run.id.uuidString), .text(issue.code.rawValue), .text(issue.severity.rawValue),
                    .text(issue.userDescription), .text(issue.technicalDescription),
                    .text(issue.recommendedAction), .blob(try encode(issue))
                ]
            )
            try statement.stepDone()
        }
    }

    private func replaceProcessingSteps(_ run: MeasurementHistoryRun) throws {
        let deletion = try prepare("DELETE FROM processing_steps WHERE run_id = ?", values: [.text(run.id.uuidString)])
        try deletion.stepDone()
        for step in run.processingSteps {
            let statement = try prepare(
                """
                INSERT INTO processing_steps(
                    id, run_id, role, sequence, operation_code, summary,
                    input_frame_count, output_frame_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                values: [
                    .text(step.id.uuidString), .text(run.id.uuidString), .text(step.role.rawValue),
                    .integer(Int64(step.sequence)), .text(step.operationCode), .text(step.summary),
                    .integer(Int64(step.inputFrameCount)), .integer(Int64(step.outputFrameCount))
                ]
            )
            try statement.stepDone()
        }
    }

    private func replaceChartCache(_ run: MeasurementHistoryRun) throws {
        let sequence = run.correlation?.sequence
        let statement = try prepare(
            """
            INSERT INTO chart_cache_metadata(
                run_id, cache_format_version, correlation_available,
                correlation_sample_count, correlation_first_lag, correlation_values,
                waveform_available, waveform_unavailable_reason
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(run_id) DO UPDATE SET
                cache_format_version=excluded.cache_format_version,
                correlation_available=excluded.correlation_available,
                correlation_sample_count=excluded.correlation_sample_count,
                correlation_first_lag=excluded.correlation_first_lag,
                correlation_values=excluded.correlation_values,
                waveform_available=excluded.waveform_available,
                waveform_unavailable_reason=excluded.waveform_unavailable_reason
            """,
            values: [
                .text(run.id.uuidString), .integer(Int64(run.chartCache.cacheFormatVersion)),
                .integer(sequence == nil ? 0 : 1), .integer(Int64(sequence?.values.count ?? 0)),
                sequence.map { .integer($0.firstLag) } ?? .null,
                sequence.map { .blob(Self.encodeFloat32($0.values)) } ?? .null,
                .integer(run.chartCache.waveformAvailable ? 1 : 0),
                optionalText(run.chartCache.waveformUnavailableReason)
            ]
        )
        try statement.stepDone()
    }

    private func loadRuns(sessionID: UUID) throws -> [MeasurementHistoryRun] {
        let statement = try prepare(
            """
            SELECT r.id, r.created_at, r.completed_at, r.correlation_json, r.quality_json,
                   r.statistics_json, r.notes, r.calibration_json, c.cache_format_version,
                   c.correlation_available, c.correlation_sample_count,
                   c.correlation_first_lag, c.correlation_values,
                   c.waveform_available, c.waveform_unavailable_reason
            FROM runs r
            JOIN chart_cache_metadata c ON c.run_id = r.id
            WHERE r.session_id = ?
            ORDER BY r.created_at ASC, r.id ASC
            """,
            values: [.text(sessionID.uuidString)]
        )
        var runs: [MeasurementHistoryRun] = []
        while try statement.stepRow() {
            guard let runID = UUID(uuidString: statement.text(0)) else {
                throw MeasurementStorageError.decodingFailed(type: "run", message: "Invalid UUID.")
            }
            let baseCorrelation: CorrelationResult? = try decodeOptional(CorrelationResult.self, data: statement.data(3))
            let correlation: CorrelationResult?
            let calibration: CalibratedDelayResult? = try decodeOptional(CalibratedDelayResult.self, data: statement.data(7))
            if let baseCorrelation, statement.bool(9), let blob = statement.data(12) {
                let values = try Self.decodeFloat32(blob)
                let sequence = CorrelationSequence(firstLag: statement.int64(11), values: values)
                correlation = CorrelationResult(
                    peakOffset: baseCorrelation.peakOffset,
                    normalizedPeak: baseCorrelation.normalizedPeak,
                    peakToSidelobeRatio: baseCorrelation.peakToSidelobeRatio,
                    confidence: baseCorrelation.confidence,
                    primaryPeak: baseCorrelation.primaryPeak,
                    secondaryPeak: baseCorrelation.secondaryPeak,
                    sequence: sequence,
                    diagnostics: baseCorrelation.diagnostics
                )
            } else {
                correlation = baseCorrelation
            }
            let quality = try decode(MeasurementQuality.self, data: statement.requiredData(4))
            let statistics: MeasurementStatistics? = try decodeOptional(MeasurementStatistics.self, data: statement.data(5))
            let files = try loadFiles(runID: runID)
            guard let reference = files.first(where: { $0.role == .reference }),
                  let recording = files.first(where: { $0.role == .recording }) else {
                throw MeasurementStorageError.decodingFailed(type: "files", message: "Reference or recording metadata is missing.")
            }
            let delay = try loadDelay(runID: runID)
            let chart = StoredChartCacheMetadata(
                cacheFormatVersion: statement.int(8),
                correlationSequenceAvailable: statement.bool(9),
                correlationSampleCount: statement.int(10),
                waveformAvailable: statement.bool(13),
                waveformUnavailableReason: statement.optionalText(14)
            )
            runs.append(
                MeasurementHistoryRun(
                    id: runID,
                    sessionID: sessionID,
                    createdAt: Date(timeIntervalSince1970: statement.double(1)),
                    completedAt: statement.optionalDouble(2).map(Date.init(timeIntervalSince1970:)),
                    referenceFile: reference,
                    recordingFile: recording,
                    delayEstimate: delay,
                    calibration: calibration,
                    correlation: correlation,
                    quality: quality,
                    statistics: statistics,
                    processingSteps: try loadProcessingSteps(runID: runID),
                    chartCache: chart,
                    notes: statement.text(6)
                )
            )
        }
        return runs
    }

    private func loadFiles(runID: UUID) throws -> [StoredAudioFileMetadata] {
        let statement = try prepare(
            """
            SELECT id, role, privacy_identifier, file_name, container, encoding,
                   format_json, frame_count, duration_seconds, peak_magnitude, rms,
                   clipping_count, dc_offset, bookmark_blob, audio_copy_relative_path
            FROM files WHERE run_id = ? ORDER BY role ASC
            """,
            values: [.text(runID.uuidString)]
        )
        var files: [StoredAudioFileMetadata] = []
        while try statement.stepRow() {
            guard let id = UUID(uuidString: statement.text(0)),
                  let role = StoredFileRole(rawValue: statement.text(1)) else {
                throw MeasurementStorageError.decodingFailed(type: "file", message: "Invalid file identity or role.")
            }
            files.append(
                StoredAudioFileMetadata(
                    id: id,
                    role: role,
                    privacyIdentifier: statement.text(2),
                    fileName: statement.text(3),
                    container: statement.text(4),
                    encoding: statement.text(5),
                    format: try decode(AudioFormatDescriptor.self, data: statement.requiredData(6)),
                    frameCount: statement.int(7),
                    durationSeconds: statement.double(8),
                    peakMagnitude: statement.double(9),
                    rootMeanSquare: statement.double(10),
                    clippingSampleCount: statement.int(11),
                    dcOffset: statement.double(12),
                    securityScopedBookmark: statement.data(13),
                    audioCopyRelativePath: statement.optionalText(14)
                )
            )
        }
        return files
    }

    private func loadDelay(runID: UUID) throws -> DelayEstimate? {
        let statement = try prepare("SELECT payload FROM delay_estimates WHERE run_id = ?", values: [.text(runID.uuidString)])
        guard try statement.stepRow() else { return nil }
        return try decode(DelayEstimate.self, data: statement.requiredData(0))
    }

    private func loadProcessingSteps(runID: UUID) throws -> [StoredProcessingStep] {
        let statement = try prepare(
            """
            SELECT id, role, sequence, operation_code, summary, input_frame_count, output_frame_count
            FROM processing_steps WHERE run_id = ? ORDER BY role ASC, sequence ASC
            """,
            values: [.text(runID.uuidString)]
        )
        var steps: [StoredProcessingStep] = []
        while try statement.stepRow() {
            guard let id = UUID(uuidString: statement.text(0)),
                  let role = StoredFileRole(rawValue: statement.text(1)) else {
                throw MeasurementStorageError.decodingFailed(type: "processing step", message: "Invalid identity or role.")
            }
            steps.append(
                StoredProcessingStep(
                    id: id,
                    role: role,
                    sequence: statement.int(2),
                    operationCode: statement.text(3),
                    summary: statement.text(4),
                    inputFrameCount: statement.int(5),
                    outputFrameCount: statement.int(6)
                )
            )
        }
        return steps
    }

    private func validate(_ session: MeasurementHistorySession) throws {
        guard !session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeasurementStorageError.invalidRecord(message: "Session name cannot be empty.")
        }
        guard !session.configurationPayload.isEmpty else {
            throw MeasurementStorageError.invalidRecord(message: "Configuration payload cannot be empty.")
        }
        let runIDs = session.runs.map(\.id)
        guard Set(runIDs).count == runIDs.count else {
            throw MeasurementStorageError.invalidRecord(message: "Run IDs must be unique within a session.")
        }
        for run in session.runs {
            guard run.sessionID == session.id else {
                throw MeasurementStorageError.invalidRecord(message: "Run session ID does not match its parent.")
            }
            try validate(file: run.referenceFile, policy: session.savePolicy)
            try validate(file: run.recordingFile, policy: session.savePolicy)
            guard run.referenceFile.role == .reference, run.recordingFile.role == .recording else {
                throw MeasurementStorageError.invalidRecord(message: "File roles do not match their fields.")
            }
        }
    }

    private func validate(file: StoredAudioFileMetadata, policy: MeasurementSavePolicy) throws {
        guard !file.fileName.isEmpty,
              !file.fileName.contains("/"),
              !file.fileName.contains("\\"),
              !file.privacyIdentifier.isEmpty else {
            throw MeasurementStorageError.invalidRecord(message: "File metadata must not contain a path.")
        }
        if let relativePath = file.audioCopyRelativePath {
            guard !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else {
                throw MeasurementStorageError.invalidRecord(message: "Audio copy path must remain relative to the app container.")
            }
        }
        switch policy {
        case .resultsOnly:
            guard file.securityScopedBookmark == nil, file.audioCopyRelativePath == nil else {
                throw MeasurementStorageError.invalidRecord(message: "Results-only records cannot retain file access or audio paths.")
            }
        case .securityScopedBookmarks:
            guard file.audioCopyRelativePath == nil else {
                throw MeasurementStorageError.invalidRecord(message: "Bookmark policy cannot retain an audio-copy path.")
            }
        case .audioCopies:
            guard file.securityScopedBookmark == nil else {
                throw MeasurementStorageError.invalidRecord(message: "Audio-copy policy cannot retain a security-scoped bookmark.")
            }
        case .doNotSave:
            break
        }
    }

    private func summary(session: MeasurementHistorySession, run: MeasurementHistoryRun) -> MeasurementHistoryRunSummary {
        MeasurementHistoryRunSummary(
            id: run.id,
            sessionID: session.id,
            sessionName: session.name,
            createdAt: run.createdAt,
            measurementType: session.measurementType,
            referenceFileName: run.referenceFile.fileName,
            recordingFileName: run.recordingFile.fileName,
            delayMilliseconds: run.delayEstimate?.fractionalMilliseconds,
            sampleRateHertz: run.delayEstimate?.sampleRate.hertz ?? run.referenceFile.format.sampleRate.hertz,
            qualityLevel: run.quality.level,
            confidence: run.quality.confidence.value,
            inputDeviceName: session.inputDevice?.name,
            outputDeviceName: session.outputDevice?.name,
            notes: run.notes.isEmpty ? session.notes : run.notes
        )
    }

    private func decodeSummary(_ statement: SQLiteStatement) throws -> MeasurementHistoryRunSummary {
        guard let id = UUID(uuidString: statement.text(0)),
              let sessionID = UUID(uuidString: statement.text(1)),
              let type = StoredMeasurementType(rawValue: statement.text(4)),
              let quality = MeasurementQualityLevel(rawValue: statement.text(9)) else {
            throw MeasurementStorageError.decodingFailed(type: "run summary", message: "Invalid identity or enum value.")
        }
        return MeasurementHistoryRunSummary(
            id: id,
            sessionID: sessionID,
            sessionName: statement.text(2),
            createdAt: Date(timeIntervalSince1970: statement.double(3)),
            measurementType: type,
            referenceFileName: statement.text(5),
            recordingFileName: statement.text(6),
            delayMilliseconds: statement.optionalDouble(7),
            sampleRateHertz: statement.double(8),
            qualityLevel: quality,
            confidence: statement.double(10),
            inputDeviceName: statement.optionalText(11),
            outputDeviceName: statement.optionalText(12),
            notes: statement.text(13)
        )
    }

    private func runQueryPredicate(_ query: MeasurementHistoryQuery) -> (sql: String, values: [SQLiteValue]) {
        var clauses: [String] = []
        var values: [SQLiteValue] = []
        let search = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            clauses.append("(rf.file_name LIKE ? ESCAPE '\\' OR ofile.file_name LIKE ? ESCAPE '\\' OR s.name LIKE ? ESCAPE '\\' OR s.notes LIKE ? ESCAPE '\\' OR r.notes LIKE ? ESCAPE '\\')")
            let value = SQLiteValue.text("%\(Self.escapeLike(search))%")
            values.append(contentsOf: Array(repeating: value, count: 5))
        }
        if !query.qualityLevels.isEmpty {
            clauses.append("r.quality_level IN (\(Array(repeating: "?", count: query.qualityLevels.count).joined(separator: ",")))")
            values.append(contentsOf: query.qualityLevels.map { .text($0.rawValue) })
        }
        let device = query.deviceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !device.isEmpty {
            clauses.append("(s.input_device_name LIKE ? ESCAPE '\\' OR s.output_device_name LIKE ? ESCAPE '\\' OR s.input_device_id = ? OR s.output_device_id = ?)")
            let like = SQLiteValue.text("%\(Self.escapeLike(device))%")
            values.append(contentsOf: [like, like, .text(device), .text(device)])
        }
        if !query.measurementTypes.isEmpty {
            clauses.append("s.measurement_type IN (\(Array(repeating: "?", count: query.measurementTypes.count).joined(separator: ",")))")
            values.append(contentsOf: query.measurementTypes.map { .text($0.rawValue) })
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), values)
    }

    private func transaction(_ body: () throws -> Void) throws {
        do {
            try Self.execute("BEGIN IMMEDIATE TRANSACTION", on: database)
            do {
                try body()
                try Self.execute("COMMIT", on: database)
            } catch {
                try? Self.execute("ROLLBACK", on: database)
                throw error
            }
        } catch let error as MeasurementStorageError {
            throw error
        } catch {
            throw MeasurementStorageError.transactionFailed(message: error.localizedDescription)
        }
    }

    private func prepare(_ sql: String, values: [SQLiteValue] = []) throws -> SQLiteStatement {
        do {
            let statement = try SQLiteStatement(database: database, sql: sql)
            try statement.bind(values)
            return statement
        } catch let error as MeasurementStorageError {
            throw error
        } catch {
            throw MeasurementStorageError.queryFailed(operation: sql, message: error.localizedDescription)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        guard try statement.stepRow() else {
            throw MeasurementStorageError.queryFailed(operation: sql, message: "No scalar row returned.")
        }
        return statement.int(0)
    }

    private func managedCopyPaths(
        sql: String,
        values: [SQLiteValue] = []
    ) throws -> [String] {
        let statement = try prepare(sql, values: values)
        var paths: [String] = []
        while try statement.stepRow() {
            if let path = statement.optionalText(0) { paths.append(path) }
        }
        return paths
    }

    private func removeManagedAudioCopies(_ relativePaths: [String]) throws {
        guard !isInMemory else { return }
        let root = databaseURL.deletingLastPathComponent().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for relativePath in Set(relativePaths) {
            guard !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else {
                throw MeasurementStorageError.invalidRecord(message: "Managed audio path escaped the application container.")
            }
            let target = root.appendingPathComponent(relativePath).standardizedFileURL
            guard target.path.hasPrefix(rootPrefix) else {
                throw MeasurementStorageError.invalidRecord(message: "Managed audio path escaped the application container.")
            }
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                throw MeasurementStorageError.queryFailed(
                    operation: "delete managed audio copy",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw MeasurementStorageError.encodingFailed(type: String(describing: T.self), message: error.localizedDescription) }
    }

    private static func exactDateData(_ date: Date) -> Data {
        var bits = date.timeIntervalSince1970.bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Data($0) }
    }

    private static func exactReferenceDateData(_ date: Date) -> Data {
        var bits = date.timeIntervalSinceReferenceDate.bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Data($0) }
    }

    private func encodeOptional<T: Encodable>(_ value: T?) throws -> Data? {
        guard let value else { return nil }
        return try encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw MeasurementStorageError.decodingFailed(type: String(describing: type), message: error.localizedDescription) }
    }

    private func decodeOptional<T: Decodable>(_ type: T.Type, data: Data?) throws -> T? {
        guard let data else { return nil }
        return try decode(type, data: data)
    }

    private func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
    private func optionalBlob(_ value: Data?) -> SQLiteValue { value.map(SQLiteValue.blob) ?? .null }
    private func optionalReal(_ value: Double?) -> SQLiteValue { value.map(SQLiteValue.real) ?? .null }
    private func optionalBool(_ value: Bool?) -> SQLiteValue { value.map { .integer($0 ? 1 : 0) } ?? .null }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func encodeFloat32(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<UInt32>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decodeFloat32(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw MeasurementStorageError.decodingFailed(type: "Float32 chart cache", message: "Byte count is not divisible by four.")
        }
        let bytes = [UInt8](data)
        var values: [Float] = []
        values.reserveCapacity(bytes.count / 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let bits = UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            values.append(Float(bitPattern: bits))
        }
        return values
    }

    private static func migrateIfNeeded(database: OpaquePointer) throws {
        let current = try scalarInt("PRAGMA user_version", database: database)
        guard current <= currentSchemaVersion else {
            throw MeasurementStorageError.migrationFailed(
                fromVersion: current,
                toVersion: currentSchemaVersion,
                message: "Database was created by a newer application version."
            )
        }
        guard current < currentSchemaVersion else { return }
        do {
            try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
            if current == 0 {
                try execute(schemaV1, on: database)
                try execute(
                    "INSERT INTO app_schema_version(singleton, current_version, migrated_at) VALUES (1, 1, strftime('%s','now'))",
                    on: database
                )
            }
            if current < 2 {
                try execute(
                    "ALTER TABLE sessions ADD COLUMN repeated_statistics_json BLOB",
                    on: database
                )
                try execute(
                    "UPDATE app_schema_version SET current_version = 2, migrated_at = strftime('%s','now') WHERE singleton = 1",
                    on: database
                )
            }
            if current < 3 {
                if try tableExists("runs", database: database) {
                    try execute("ALTER TABLE runs ADD COLUMN calibration_json BLOB", on: database)
                }
                try execute(schemaV3, on: database)
                try execute(
                    "UPDATE app_schema_version SET current_version = 3, migrated_at = strftime('%s','now') WHERE singleton = 1",
                    on: database
                )
            }
            if current < 4 {
                try execute(schemaV4, on: database)
                try execute(
                    "UPDATE app_schema_version SET current_version = 4, migrated_at = strftime('%s','now') WHERE singleton = 1",
                    on: database
                )
            }
            if current < 5 {
                try execute(schemaV5, on: database)
                try execute(
                    "UPDATE app_schema_version SET current_version = 5, migrated_at = strftime('%s','now') WHERE singleton = 1",
                    on: database
                )
            }
            try execute("PRAGMA user_version = \(currentSchemaVersion)", on: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw MeasurementStorageError.migrationFailed(
                fromVersion: current,
                toVersion: currentSchemaVersion,
                message: String(describing: error)
            )
        }
    }

    private static func scalarInt(_ sql: String, database: OpaquePointer) throws -> Int {
        let statement = try SQLiteStatement(database: database, sql: sql)
        guard try statement.stepRow() else {
            throw MeasurementStorageError.queryFailed(operation: sql, message: "No scalar row returned.")
        }
        return statement.int(0)
    }

    private static func createMigrationBackup(
        databaseURL: URL,
        database: OpaquePointer,
        fromVersion: Int
    ) throws {
        // Checkpoint the WAL before copying so the backup is self-contained.
        try execute("PRAGMA wal_checkpoint(TRUNCATE)", on: database)
        let backupURL = databaseURL.appendingPathExtension("pre-migration-v\(fromVersion)")
        // Never overwrite a recovery point left by an earlier failed launch.
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try FileManager.default.copyItem(at: databaseURL, to: backupURL)
    }

    private static func tableExists(_ name: String, database: OpaquePointer) throws -> Bool {
        let statement = try SQLiteStatement(
            database: database,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name.replacingOccurrences(of: "'", with: "''"))' LIMIT 1"
        )
        return try statement.stepRow()
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            if result == SQLITE_CORRUPT || result == SQLITE_NOTADB {
                throw MeasurementStorageError.corruptDatabase(message: message)
            }
            if result == SQLITE_CONSTRAINT {
                throw MeasurementStorageError.constraintViolation(message: message)
            }
            throw MeasurementStorageError.queryFailed(operation: sql, message: message)
        }
    }

    private static let schemaV1 = """
    CREATE TABLE app_schema_version (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
        current_version INTEGER NOT NULL,
        migrated_at REAL NOT NULL
    );
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY, created_at REAL NOT NULL, updated_at REAL NOT NULL,
        name TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '', measurement_type TEXT NOT NULL,
        save_policy TEXT NOT NULL, app_version TEXT NOT NULL, algorithm_version TEXT NOT NULL,
        input_device_id TEXT, input_device_name TEXT, output_device_id TEXT, output_device_name TEXT,
        input_device_json BLOB, output_device_json BLOB, statistics_json BLOB
    );
    CREATE TABLE configurations (
        session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
        payload BLOB NOT NULL, summary_json BLOB NOT NULL
    );
    CREATE TABLE runs (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        created_at REAL NOT NULL, completed_at REAL, quality_level TEXT NOT NULL,
        confidence REAL NOT NULL, delay_ms REAL, sample_rate_hz REAL NOT NULL,
        correlation_json BLOB, quality_json BLOB NOT NULL, statistics_json BLOB,
        notes TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX runs_created_at_index ON runs(created_at DESC);
    CREATE INDEX runs_quality_index ON runs(quality_level);
    CREATE TABLE files (
        id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        role TEXT NOT NULL, privacy_identifier TEXT NOT NULL, file_name TEXT NOT NULL,
        container TEXT NOT NULL, encoding TEXT NOT NULL, format_json BLOB NOT NULL,
        frame_count INTEGER NOT NULL, duration_seconds REAL NOT NULL,
        peak_magnitude REAL NOT NULL, rms REAL NOT NULL, clipping_count INTEGER NOT NULL,
        dc_offset REAL NOT NULL, bookmark_blob BLOB, audio_copy_relative_path TEXT,
        UNIQUE(run_id, role)
    );
    CREATE INDEX files_name_index ON files(file_name);
    CREATE TABLE delay_estimates (
        run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
        sample_offset INTEGER NOT NULL, fractional_sample_offset REAL,
        sample_rate_hz REAL NOT NULL, confidence REAL NOT NULL,
        peak_amplitude REAL, peak_to_sidelobe_ratio REAL, is_reliable INTEGER,
        payload BLOB NOT NULL
    );
    CREATE TABLE quality_metrics (
        run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        code TEXT NOT NULL, value REAL NOT NULL, unit TEXT NOT NULL,
        normalized_score REAL NOT NULL, weight REAL NOT NULL,
        ideal_minimum REAL, ideal_maximum REAL, explanation TEXT NOT NULL,
        payload BLOB NOT NULL, PRIMARY KEY(run_id, code)
    );
    CREATE TABLE quality_issues (
        run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        code TEXT NOT NULL, severity TEXT NOT NULL, user_description TEXT NOT NULL,
        technical_description TEXT NOT NULL, recommended_action TEXT NOT NULL,
        payload BLOB NOT NULL, PRIMARY KEY(run_id, code)
    );
    CREATE TABLE processing_steps (
        id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        role TEXT NOT NULL, sequence INTEGER NOT NULL, operation_code TEXT NOT NULL,
        summary TEXT NOT NULL, input_frame_count INTEGER NOT NULL,
        output_frame_count INTEGER NOT NULL,
        UNIQUE(run_id, role, sequence)
    );
    CREATE TABLE chart_cache_metadata (
        run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
        cache_format_version INTEGER NOT NULL, correlation_available INTEGER NOT NULL,
        correlation_sample_count INTEGER NOT NULL, correlation_first_lag INTEGER,
        correlation_values BLOB, waveform_available INTEGER NOT NULL,
        waveform_unavailable_reason TEXT
    );
    """

    private static let schemaV3 = """
    CREATE TABLE IF NOT EXISTS calibration_profiles (
        id TEXT PRIMARY KEY,
        profile_name TEXT NOT NULL,
        input_device_json BLOB NOT NULL,
        output_device_json BLOB NOT NULL,
        channel_mapping_json BLOB NOT NULL,
        sample_rate_hz REAL NOT NULL,
        buffer_frame_count INTEGER NOT NULL,
        known_fixed_delay_samples INTEGER NOT NULL,
        confidence REAL NOT NULL,
        calibration_method TEXT NOT NULL,
        measurement_date REAL NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        subtract_offset_by_default INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS calibration_profiles_date_index ON calibration_profiles(measurement_date DESC);
    """

    private static let schemaV4 = """
    CREATE TABLE IF NOT EXISTS device_snapshots (
        id TEXT PRIMARY KEY,
        identity TEXT NOT NULL,
        captured_at REAL NOT NULL,
        name TEXT NOT NULL,
        manufacturer TEXT,
        transport TEXT NOT NULL,
        payload BLOB NOT NULL,
        anonymized INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX IF NOT EXISTS device_snapshots_identity_index ON device_snapshots(identity, captured_at DESC);
    """

    private static let schemaV5 = """
    CREATE TABLE IF NOT EXISTS lab_artifacts (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        created_at BLOB NOT NULL,
        updated_at BLOB NOT NULL,
        payload BLOB NOT NULL,
        anonymized INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX IF NOT EXISTS lab_artifacts_kind_index ON lab_artifacts(kind, updated_at DESC);
    """
}

private enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// The repository actor is the sole owner and caller of this FULLMUTEX SQLite
/// connection. The wrapper is unchecked only so its deinitializer can close the
/// C handle without crossing actor isolation.
private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}

private final class SQLiteStatement {
    private let database: OpaquePointer
    private let statement: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else {
            throw MeasurementStorageError.queryFailed(
                operation: sql,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        self.statement = prepared
    }

    deinit { sqlite3_finalize(statement) }

    func bind(_ values: [SQLiteValue]) throws {
        guard values.count == sqlite3_bind_parameter_count(statement) else {
            throw MeasurementStorageError.queryFailed(
                operation: "bind",
                message: "Expected \(sqlite3_bind_parameter_count(statement)) values, received \(values.count)."
            )
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case let .integer(number):
                result = sqlite3_bind_int64(statement, index, number)
            case let .real(number):
                result = sqlite3_bind_double(statement, index, number)
            case let .text(text):
                result = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let .blob(data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else {
                throw MeasurementStorageError.queryFailed(operation: "bind", message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    func stepRow() throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw mappedError(operation: "read row", code: result)
    }

    func stepDone() throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw mappedError(operation: "execute statement", code: result) }
    }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func dateIntervalSince1970(_ column: Int32) -> Double {
        if sqlite3_column_type(statement, column) == SQLITE_BLOB,
           let bytes = data(column), bytes.count == MemoryLayout<UInt64>.size {
            var bits: UInt64 = 0
            for (offset, byte) in bytes.enumerated() {
                bits |= UInt64(byte) << UInt64(offset * 8)
            }
            return Double(bitPattern: UInt64(littleEndian: bits))
        }
        if sqlite3_column_type(statement, column) == SQLITE_INTEGER {
            return Double(bitPattern: UInt64(bitPattern: sqlite3_column_int64(statement, column)))
        }
        return sqlite3_column_double(statement, column)
    }
    func referenceDate(_ column: Int32) -> Date {
        if sqlite3_column_type(statement, column) == SQLITE_BLOB,
           let bytes = data(column), bytes.count == MemoryLayout<UInt64>.size {
            var bits: UInt64 = 0
            for (offset, byte) in bytes.enumerated() { bits |= UInt64(byte) << UInt64(offset * 8) }
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: UInt64(littleEndian: bits)))
        }
        return Date(timeIntervalSince1970: dateIntervalSince1970(column))
    }
    func bool(_ column: Int32) -> Bool { sqlite3_column_int(statement, column) != 0 }
    func optionalDouble(_ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }
    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
    func optionalText(_ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
    }
    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    func requiredData(_ column: Int32) throws -> Data {
        guard let value = data(column) else {
            throw MeasurementStorageError.decodingFailed(type: "BLOB", message: "Required data is NULL.")
        }
        return value
    }

    private func mappedError(operation: String, code: Int32) -> MeasurementStorageError {
        let message = String(cString: sqlite3_errmsg(database))
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            return .corruptDatabase(message: message)
        }
        if code == SQLITE_CONSTRAINT {
            return .constraintViolation(message: message)
        }
        return .queryFailed(operation: operation, message: message)
    }

    private static var transient: sqlite3_destructor_type {
        // SQLite documents SQLITE_TRANSIENT as the sentinel pointer -1. The
        // C module exposes the destructor type but not a typed constant, so
        // this is the one intentional FFI cast in the storage boundary.
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}

private extension Set where Element == String {
    func symmetricDifference(_ other: Set<String>) -> Set<String> {
        subtracting(other).union(other.subtracting(self))
    }
}
