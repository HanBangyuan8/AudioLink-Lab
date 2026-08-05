import AudioLinkCore
import AudioLinkStorage
import Foundation
import SQLite3
import Testing

@Test
func emptyDatabaseMigratesToLatestSchemaWithRequiredTables() async throws {
    try await withTemporaryDatabase { url, repository in
        let info = try await repository.repositoryInfo()
        #expect(info.schemaVersion == 5)
        #expect(info.sessionCount == 0)
        #expect(info.runCount == 0)

        let tables = try sqliteStrings(
            url: url,
            sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )
        for required in [
            "app_schema_version", "sessions", "runs", "files", "configurations",
            "delay_estimates", "quality_metrics", "quality_issues",
            "processing_steps", "chart_cache_metadata"
            , "device_snapshots", "lab_artifacts"
        ] {
            #expect(tables.contains(required))
        }
    }
}

@Test
func calibrationProfilesRoundTripAndCanBeDeleted() async throws {
    try await withTemporaryDatabase { _, repository in
        let sampleRate = SampleRate.hz48000
        let input = DeviceDescriptor(id: "input-cal", name: "Input", supportsInput: true, supportsOutput: false)
        let output = DeviceDescriptor(id: "output-cal", name: "Output", supportsInput: false, supportsOutput: true)
        let profile = CalibrationProfile(
            profileName: "Loopback A",
            inputDevice: input,
            outputDevice: output,
            channelMapping: CalibrationChannelMapping(inputChannel: 0, outputChannel: 0),
            sampleRate: sampleRate,
            bufferFrameCount: 256,
            knownFixedDelay: CalibrationOffset(sampleCount: SampleCount(rawValue: 128), sampleRate: sampleRate),
            measurementDate: Date(timeIntervalSince1970: 1_700_000_000),
            confidence: 0.95,
            calibrationMethod: .physicalLoopback
        )
        try await repository.saveCalibrationProfile(profile)
        let loadedProfile = try await repository.calibrationProfile(id: profile.id)
        #expect(loadedProfile == profile)
        #expect(try await repository.calibrationProfiles().count == 1)
        try await repository.deleteCalibrationProfile(id: profile.id)
        #expect(try await repository.calibrationProfile(id: profile.id) == nil)
    }
}

@Test
func deviceSnapshotsRoundTripWithoutPersistingAbsolutePath() async throws {
    try await withTemporaryDatabase { _, repository in
        let record = DeviceSnapshotRecord(identity: "uid:test", capturedAt: Date(timeIntervalSince1970: 1_700_000_000), name: "USB Interface", manufacturer: "Acme", transport: "usb", payload: Data("{\"path\":\"redacted\"}".utf8), isAnonymized: true)
        try await repository.saveDeviceSnapshot(record)
        let loaded = try await repository.deviceSnapshots(identity: "uid:test")
        #expect(loaded == [record])
        try await repository.deleteDeviceSnapshot(id: record.id)
        #expect(try await repository.deviceSnapshots().isEmpty)
    }
}

@Test
func labArtifactsRoundTripForAdaptiveSpatialAndDistributedPayloads() async throws {
    try await withTemporaryDatabase { _, repository in
        let record = LabArtifactRecord(kind: "spatial.project", payload: Data("{\"version\":1}".utf8))
        try await repository.saveLabArtifact(record)
        let loaded = try await repository.labArtifacts(kind: "spatial.project")
        #expect(loaded == [record])
        try await repository.deleteLabArtifact(id: record.id)
        #expect(try await repository.labArtifacts().isEmpty)
    }
}

@Test
func legacySessionStorePersistsAcrossStoreInstances() async throws {
    try await withTemporaryDatabase { _, repository in
        let configuration = MeasurementConfiguration(
            format: AudioFormatDescriptor(sampleRate: .hz48000, channelCount: 1, bitDepth: 32, isInterleaved: false),
            signal: .impulse,
            measurementDuration: try DurationSeconds(0.1),
            repetitions: 1
        )
        let session = MeasurementSession(createdAt: Date(timeIntervalSince1970: 1_700_000_000), name: "Compatibility", configuration: configuration)
        let firstStore = SQLiteMeasurementSessionStore(repository: repository)
        try await firstStore.save(session)

        let secondStore = SQLiteMeasurementSessionStore(repository: repository)
        #expect(try await secondStore.session(id: session.id) == session)
        #expect(try await secondStore.sessions().count == 1)
        try await secondStore.deleteSession(id: session.id)
        #expect(try await secondStore.sessions().isEmpty)
    }
}

@Test
func repeatedStatisticsRoundTripWithoutChangingRawRuns() async throws {
    try await withTemporaryDatabase { _, repository in
        let base = try historyFixture(index: 7_700)
        let aggregate = repeatedStatisticsFixture()
        let session = MeasurementHistorySession(
            id: base.id,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt,
            name: base.name,
            notes: base.notes,
            measurementType: base.measurementType,
            savePolicy: base.savePolicy,
            configurationPayload: base.configurationPayload,
            configurationSummary: base.configurationSummary,
            statistics: base.statistics,
            repeatedStatistics: aggregate,
            inputDevice: base.inputDevice,
            outputDevice: base.outputDevice,
            appVersion: base.appVersion,
            algorithmVersion: base.algorithmVersion,
            runs: base.runs
        )
        try await repository.saveSession(session)

        let loaded = try #require(try await repository.session(id: session.id))
        #expect(loaded.repeatedStatistics == aggregate)
        #expect(loaded.runs == base.runs)
    }
}

@Test
func targetedRepeatedStatisticsUpdateDoesNotRewriteOrRemoveRuns() async throws {
    try await withTemporaryDatabase { _, repository in
        let base = try historyFixture(index: 7_701)
        try await repository.saveSession(base)
        let aggregate = repeatedStatisticsFixture()
        let payload = Data("plan-v2".utf8)
        let summary = ["measurementMode": "repeated", "runCount": "20"]

        try await repository.updateRepeatedStatistics(
            sessionID: base.id,
            statistics: aggregate,
            configurationPayload: payload,
            configurationSummary: summary,
            updatedAt: base.updatedAt.addingTimeInterval(1)
        )

        let loaded = try #require(try await repository.session(id: base.id))
        #expect(loaded.repeatedStatistics == aggregate)
        #expect(loaded.configurationPayload == payload)
        #expect(loaded.configurationSummary == summary)
        #expect(loaded.runs == base.runs)
    }
}

@Test
func sessionRoundTripPreservesResultsDiagnosticsAndChartSequence() async throws {
    try await withTemporaryDatabase { _, repository in
        let original = try historyFixture(index: 1)
        try await repository.saveSession(original)

        let loaded = try #require(try await repository.session(id: original.id))
        #expect(loaded == original)
        #expect(loaded.runs[0].correlation?.sequence?.values == original.runs[0].correlation?.sequence?.values)
        #expect(loaded.runs[0].chartCache.correlationSequenceAvailable)
        #expect(!loaded.runs[0].chartCache.waveformAvailable)
    }
}

@Test
func recordsRemainAvailableThroughASecondRepositoryConnection() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let original = try historyFixture(index: 50)
    let writer = try SQLiteMeasurementRepository(databaseURL: url)
    try await writer.saveSession(original)

    let reader = try SQLiteMeasurementRepository(databaseURL: url)
    let loaded = try #require(try await reader.session(id: original.id))
    #expect(loaded == original)
}

@Test
func updateAndDeleteOperationsArePersistent() async throws {
    try await withTemporaryDatabase { _, repository in
        let original = try historyFixture(index: 2)
        try await repository.saveSession(original)
        try await repository.updateSession(id: original.id, name: "Updated Session", notes: "bench A")
        let updated = try #require(try await repository.session(id: original.id))
        #expect(updated.name == "Updated Session")
        #expect(updated.notes == "bench A")

        try await repository.deleteRun(id: original.runs[0].id)
        #expect(try await repository.run(id: original.runs[0].id) == nil)
        try await repository.deleteSession(id: original.id)
        #expect(try await repository.session(id: original.id) == nil)
    }
}

@Test
func failedSaveRollsBackItsAlreadyInsertedSession() async throws {
    try await withTemporaryDatabase { url, repository in
        let fixture = try historyFixture(index: 3)
        let blockedRunID = fixture.runs[0].id.uuidString
        try sqliteExecute(
            url: url,
            sql: """
            CREATE TRIGGER reject_test_run BEFORE INSERT ON runs
            WHEN NEW.id = '\(blockedRunID)'
            BEGIN SELECT RAISE(ABORT, 'test rollback'); END;
            """
        )

        await #expect(throws: MeasurementStorageError.self) {
            try await repository.saveSession(fixture)
        }
        #expect(try await repository.session(id: fixture.id) == nil)
        let info = try await repository.repositoryInfo()
        #expect(info.sessionCount == 0)
        #expect(info.runCount == 0)
    }
}

@Test
func migrationPreservesPreexistingUnrelatedData() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    try sqliteExecute(url: url, sql: "CREATE TABLE legacy_marker(value TEXT); INSERT INTO legacy_marker VALUES ('preserve-me');")

    let repository = try SQLiteMeasurementRepository(databaseURL: url)
    let info = try await repository.repositoryInfo()
        #expect(info.schemaVersion == 5)
    #expect(try sqliteStrings(url: url, sql: "SELECT value FROM legacy_marker") == ["preserve-me"])
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("pre-migration-v0").path))
}

@Test
func schemaV1MigratesToV2WithoutDeletingExistingSessionRows() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    try sqliteExecute(
        url: url,
        sql: """
        CREATE TABLE app_schema_version (
            singleton INTEGER PRIMARY KEY,
            current_version INTEGER NOT NULL,
            migrated_at REAL NOT NULL
        );
        INSERT INTO app_schema_version VALUES (1, 1, 0);
        CREATE TABLE sessions (id TEXT PRIMARY KEY, legacy_name TEXT);
        INSERT INTO sessions VALUES ('legacy-session', 'keep-me');
        PRAGMA user_version = 1;
        """
    )

    _ = try SQLiteMeasurementRepository(databaseURL: url)

    #expect(try sqliteStrings(url: url, sql: "PRAGMA user_version") == ["5"])
    #expect(try sqliteStrings(url: url, sql: "SELECT legacy_name FROM sessions WHERE id = 'legacy-session'") == ["keep-me"])
    #expect(try sqliteStrings(url: url, sql: "SELECT name FROM pragma_table_info('sessions')").contains("repeated_statistics_json"))
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("pre-migration-v1").path))
}

@Test
func corruptDatabaseReturnsStructuredErrorWithoutReplacingFile() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("broken.sqlite")
    let original = Data("this is not sqlite".utf8)
    try original.write(to: url)

    #expect(throws: MeasurementStorageError.self) {
        _ = try SQLiteMeasurementRepository(databaseURL: url)
    }
    #expect(try Data(contentsOf: url) == original)
}

@Test
func concurrentWritesAreSerializedAndRemainQueryable() async throws {
    try await withTemporaryDatabase { _, repository in
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await repository.saveSession(historyFixture(index: 100 + index))
                }
            }
            try await group.waitForAll()
        }
        let info = try await repository.repositoryInfo()
        #expect(info.sessionCount == 40)
        #expect(info.runCount == 40)
    }
}

@Test
func paginationSearchAndFiltersRemainStableWithManyRuns() async throws {
    try await withTemporaryDatabase { _, repository in
        let fixtures = try (0..<125).map { index in
            try historyFixture(
                index: 1_000 + index,
                fileStem: index.isMultiple(of: 10) ? "special-loopback" : "ordinary",
                qualityLevel: index.isMultiple(of: 2) ? .good : .questionable,
                measurementType: index.isMultiple(of: 3) ? .offlineFile : .liveAudio
            )
        }
        try await repository.saveSessions(fixtures)

        let first = try await repository.runs(matching: .init(pageSize: 25, offset: 0))
        let last = try await repository.runs(matching: .init(pageSize: 25, offset: 100))
        #expect(first.totalCount == 125)
        #expect(first.runs.count == 25)
        #expect(first.hasMore)
        #expect(last.runs.count == 25)
        #expect(!last.hasMore)
        #expect(Set(first.runs.map(\.id)).isDisjoint(with: Set(last.runs.map(\.id))))

        let filtered = try await repository.runs(
            matching: .init(
                searchText: "special-loopback",
                qualityLevels: [.good],
                measurementTypes: [.offlineFile],
                pageSize: 100
            )
        )
        #expect(filtered.runs.allSatisfy { $0.referenceFileName.contains("special-loopback") })
        #expect(filtered.runs.allSatisfy { $0.qualityLevel == .good })
        #expect(filtered.runs.allSatisfy { $0.measurementType == .offlineFile })
    }
}

@Test
func resultsOnlyPolicyRejectsPathsBookmarksAndAudioReferences() async throws {
    try await withTemporaryDatabase { _, repository in
        let safe = try historyFixture(index: 4)
        try await repository.saveSession(safe)
        let loaded = try #require(try await repository.session(id: safe.id))
        #expect(loaded.runs[0].referenceFile.securityScopedBookmark == nil)
        #expect(loaded.runs[0].referenceFile.audioCopyRelativePath == nil)

        let unsafeFile = StoredAudioFileMetadata(
            role: .reference,
            privacyIdentifier: "id",
            fileName: "/Users/alice/private.wav",
            container: "wav",
            encoding: "float32",
            format: safe.runs[0].referenceFile.format,
            frameCount: 10,
            durationSeconds: 1,
            peakMagnitude: 0.5,
            rootMeanSquare: 0.1,
            clippingSampleCount: 0,
            dcOffset: 0,
            securityScopedBookmark: Data([1, 2, 3])
        )
        let unsafeRun = replacingReference(in: safe.runs[0], with: unsafeFile)
        let unsafeSession = replacingRuns(in: safe, with: [unsafeRun])
        await #expect(throws: MeasurementStorageError.self) {
            try await repository.saveSession(unsafeSession)
        }
    }
}

@Test
func comparisonReportsDelayConfigurationPreprocessingAndDeviceDifferences() async throws {
    try await withTemporaryDatabase { _, repository in
        let first = try historyFixture(index: 5, delaySamples: 48, configurationValue: "none")
        let second = try historyFixture(index: 6, delaySamples: 96, configurationValue: "peak")
        try await repository.saveSessions([first, second])

        let comparison = try await repository.comparison(runIDs: [first.runs[0].id, second.runs[0].id])
        #expect(comparison.baselineRunID == first.runs[0].id)
        #expect(comparison.entries.count == 2)
        #expect(comparison.entries[0].delayDifferenceMilliseconds == 0)
        #expect(abs((comparison.entries[1].delayDifferenceMilliseconds ?? 0) - 1) < 0.000_001)
        #expect(comparison.entries[1].configurationDifferences.contains("normalization"))
        #expect(!comparison.entries[1].preprocessingDifferences.isEmpty)
    }
}

@Test
func appendingRunsKeepsSessionBoundaryAndRecomputesStatistics() async throws {
    try await withTemporaryDatabase { _, repository in
        let original = try historyFixture(index: 20, delaySamples: 48)
        try await repository.saveSession(original)
        let secondFixture = try historyFixture(index: 21, delaySamples: 96)
        let source = secondFixture.runs[0]
        let appended = MeasurementHistoryRun(
            id: source.id,
            sessionID: original.id,
            createdAt: original.createdAt.addingTimeInterval(10),
            completedAt: original.createdAt.addingTimeInterval(10.5),
            referenceFile: source.referenceFile,
            recordingFile: source.recordingFile,
            delayEstimate: source.delayEstimate,
            correlation: source.correlation,
            quality: source.quality,
            statistics: source.statistics,
            processingSteps: source.processingSteps,
            chartCache: source.chartCache
        )
        try await repository.appendRun(appended, toSession: original.id)

        let session = try #require(try await repository.session(id: original.id))
        #expect(session.runs.count == 2)
        #expect(session.statistics?.sampleSize == 2)
        #expect(session.statistics?.meanDelay.rawValue == 72)
        #expect(session.statistics?.minimumDelay.rawValue == 48)
        #expect(session.statistics?.maximumDelay.rawValue == 96)
        #expect(abs((session.statistics?.jitterStandardDeviation.milliseconds ?? 0) - 0.5) < 0.000_001)
        #expect(session.statistics?.clockDrift != nil)
    }
}

private func withTemporaryDatabase(
    _ operation: (URL, SQLiteMeasurementRepository) async throws -> Void
) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let repository = try SQLiteMeasurementRepository(databaseURL: url)
    try await operation(url, repository)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioLinkStorageTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func historyFixture(
    index: Int,
    fileStem: String = "reference",
    qualityLevel: MeasurementQualityLevel = .good,
    measurementType: StoredMeasurementType = .offlineFile,
    delaySamples: Int64 = 48,
    configurationValue: String = "none"
) throws -> MeasurementHistorySession {
    let sessionID = UUID()
    let runID = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
    let format = AudioFormatDescriptor(sampleRate: .hz48000, channelCount: 1, bitDepth: 32, isInterleaved: false)
    let reference = StoredAudioFileMetadata(
        role: .reference,
        privacyIdentifier: "ref-\(index)",
        fileName: "\(fileStem)-\(index).wav",
        container: "wav",
        encoding: "ieeeFloat",
        format: format,
        frameCount: 4_096,
        durationSeconds: 4_096 / 48_000,
        peakMagnitude: 0.8,
        rootMeanSquare: 0.2,
        clippingSampleCount: 0,
        dcOffset: 0.001
    )
    let recording = StoredAudioFileMetadata(
        role: .recording,
        privacyIdentifier: "rec-\(index)",
        fileName: "recording-\(index).wav",
        container: "wav",
        encoding: "ieeeFloat",
        format: format,
        frameCount: 4_200,
        durationSeconds: 4_200 / 48_000,
        peakMagnitude: 0.75,
        rootMeanSquare: 0.18,
        clippingSampleCount: 0,
        dcOffset: 0.002
    )
    let delay = DelayEstimate(
        sampleOffset: SampleCount(rawValue: delaySamples),
        sampleRate: .hz48000,
        confidence: 0.91,
        fractionalSampleOffset: Double(delaySamples) + 0.25,
        peakAmplitude: 0.94,
        peakToSidelobeRatio: 12,
        isReliable: true
    )
    let peak = CorrelationPeak(
        lag: SampleCount(rawValue: delaySamples),
        fractionalLag: Double(delaySamples) + 0.25,
        value: 0.94,
        overlapCount: SampleCount(rawValue: 4_000)
    )
    let diagnostics = AnalysisDiagnostics(
        implementation: .fft,
        validity: .valid,
        validLagRange: SampleLagRange(minimum: -100, maximum: 200),
        searchedLagRange: SampleLagRange(minimum: 0, maximum: 200),
        searchRangeWasClamped: false,
        peakAtSearchBoundary: false,
        referenceRMS: 0.2,
        observedRMS: 0.18,
        minimumOverlapCount: SampleCount(rawValue: 2_000),
        fftLength: 8_192,
        estimatedWorkingSetBytes: 65_536,
        interpolationStatus: .applied
    )
    var values = [Float](repeating: 0.01, count: 301)
    values[Int(delaySamples + 100)] = 0.94
    let correlation = CorrelationResult(
        peakOffset: SampleCount(rawValue: delaySamples),
        normalizedPeak: 0.94,
        peakToSidelobeRatio: 12,
        confidence: 0.91,
        primaryPeak: peak,
        sequence: CorrelationSequence(firstLag: -100, values: values),
        diagnostics: diagnostics
    )
    let metric = QualityMetric(
        code: .primaryCorrelation,
        value: 0.94,
        unit: .coefficient,
        normalizedScore: 0.95,
        weight: 1,
        idealMinimum: 0.75,
        explanation: "A strong normalized peak supports the selected lag."
    )
    let issue = QualityIssue(
        code: .sampleRateConverted,
        severity: .information,
        userDescription: "The recording sample rate was converted.",
        technicalDescription: "Converted before correlation.",
        recommendedAction: "Use matching sample rates when conversion is undesirable."
    )
    let quality = MeasurementQuality(
        level: qualityLevel,
        confidence: ConfidenceScore(value: 0.88, components: []),
        summary: "The measurement has a dominant peak.",
        metrics: [metric],
        issues: [issue],
        peakAmbiguity: PeakAmbiguity(
            candidates: [peak],
            primaryToSecondaryRatio: nil,
            hasSimilarPeaks: false,
            peakSpacings: [],
            periodicInterval: nil,
            explanation: "One peak dominates."
        ),
        signal: SignalQualityAnalysis(
            referenceRMS: 0.2,
            observedRMS: 0.18,
            signalToNoiseDecibels: 32,
            clippingRatio: 0,
            dcOffsetMagnitude: 0.002,
            referenceCoverageRatio: 1,
            isPolarityInverted: false,
            appearsTruncated: false,
            channelsConsistent: true,
            channelDelaySpreadSamples: 0,
            channelPeakSpread: 0
        ),
        delayDiagnostics: DelayEstimateDiagnostics(
            selectedDelay: delay,
            candidatePeaks: [peak],
            peakWidthSamples: 2.2,
            localPeakSharpness: 0.7,
            searchBoundaryDistance: SampleCount(rawValue: 100),
            channelResults: []
        ),
        shouldRemeasure: false
    )
    let processing = StoredProcessingStep(
        role: .recording,
        sequence: 0,
        operationCode: configurationValue,
        summary: "Normalization \(configurationValue)",
        inputFrameCount: 4_200,
        outputFrameCount: 4_200
    )
    let run = MeasurementHistoryRun(
        id: runID,
        sessionID: sessionID,
        createdAt: date,
        completedAt: date.addingTimeInterval(0.5),
        referenceFile: reference,
        recordingFile: recording,
        delayEstimate: delay,
        correlation: correlation,
        quality: quality,
        processingSteps: [processing],
        chartCache: StoredChartCacheMetadata(
            correlationSequenceAvailable: true,
            correlationSampleCount: values.count,
            waveformAvailable: false,
            waveformUnavailableReason: "Raw audio is not retained by the results-only policy."
        )
    )
    return MeasurementHistorySession(
        id: sessionID,
        createdAt: date,
        updatedAt: date,
        name: "Session \(index)",
        notes: index.isMultiple(of: 7) ? "lab bench" : "",
        measurementType: measurementType,
        configurationPayload: try JSONEncoder().encode(["normalization": configurationValue]),
        configurationSummary: ["normalization": configurationValue, "method": "automatic"],
        inputDevice: DeviceDescriptor(id: "input-\(index % 3)", name: "Input \(index % 3)", supportsInput: true, supportsOutput: false),
        outputDevice: DeviceDescriptor(id: "output-1", name: "Output 1", supportsInput: false, supportsOutput: true),
        appVersion: "0.1.0",
        algorithmVersion: "correlation-v1-quality-v1",
        runs: [run]
    )
}

private func replacingReference(
    in run: MeasurementHistoryRun,
    with reference: StoredAudioFileMetadata
) -> MeasurementHistoryRun {
    MeasurementHistoryRun(
        id: run.id,
        sessionID: run.sessionID,
        createdAt: run.createdAt,
        completedAt: run.completedAt,
        referenceFile: reference,
        recordingFile: run.recordingFile,
        delayEstimate: run.delayEstimate,
        correlation: run.correlation,
        quality: run.quality,
        statistics: run.statistics,
        processingSteps: run.processingSteps,
        chartCache: run.chartCache,
        notes: run.notes
    )
}

private func replacingRuns(
    in session: MeasurementHistorySession,
    with runs: [MeasurementHistoryRun]
) -> MeasurementHistorySession {
    MeasurementHistorySession(
        id: session.id,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        name: session.name,
        notes: session.notes,
        measurementType: session.measurementType,
        savePolicy: session.savePolicy,
        configurationPayload: session.configurationPayload,
        configurationSummary: session.configurationSummary,
        statistics: session.statistics,
        repeatedStatistics: session.repeatedStatistics,
        inputDevice: session.inputDevice,
        outputDevice: session.outputDevice,
        appVersion: session.appVersion,
        algorithmVersion: session.algorithmVersion,
        runs: runs
    )
}

private func repeatedStatisticsFixture() -> RepeatedMeasurementStatistics {
    RepeatedMeasurementStatistics(
        outcomeCount: 5,
        successCount: 4,
        failureCount: 1,
        populationCount: 3,
        includesMarkedOutliers: false,
        minimumMilliseconds: 9.9,
        maximumMilliseconds: 10.2,
        meanMilliseconds: 10.05,
        medianMilliseconds: 10.0,
        varianceMillisecondsSquared: 0.02,
        jitterStandardDeviationMilliseconds: 0.141_421,
        percentile50Milliseconds: 10.0,
        percentile90Milliseconds: 10.16,
        percentile95Milliseconds: 10.18,
        percentile99Milliseconds: 10.196,
        peakToPeakJitterMilliseconds: 0.3,
        medianAbsoluteDeviationMilliseconds: 0.1,
        interquartileRangeMilliseconds: 0.15,
        confidenceInterval: StatisticalConfidenceInterval(
            confidenceLevel: 0.95,
            lowerBoundMilliseconds: 9.8,
            upperBoundMilliseconds: 10.3,
            method: "Student t"
        ),
        qualityDistribution: QualityLevelDistribution(excellent: 2, good: 1),
        outliers: [
            MeasurementOutlier(
                runID: UUID(),
                runIndex: 4,
                delayMilliseconds: 80,
                method: .medianAbsoluteDeviation,
                threshold: 3.5,
                score: 12,
                explanation: "fixture"
            )
        ],
        outlierMethod: .medianAbsoluteDeviation,
        outlierThreshold: 3.5,
        reliability: .insufficient
    )
}

private func sqliteExecute(url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw MeasurementStorageError.unableToOpenDatabase(message: "Test database open failed.")
    }
    defer { sqlite3_close_v2(database) }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "SQLite code \(result)"
        sqlite3_free(message)
        throw MeasurementStorageError.queryFailed(operation: sql, message: detail)
    }
}

private func sqliteStrings(url: URL, sql: String) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw MeasurementStorageError.unableToOpenDatabase(message: "Test database open failed.")
    }
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw MeasurementStorageError.queryFailed(operation: sql, message: String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text)) }
    }
    return values
}
