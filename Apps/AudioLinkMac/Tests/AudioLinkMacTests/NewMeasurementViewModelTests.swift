import AppKit
import AudioLinkCore
import AudioLinkDSP
import AudioLinkStorage
import Foundation
import Testing
@testable import AudioLinkMac

@Test @MainActor
func importFailureProducesRecoverableFeatureFailure() async throws {
    let fixture = try makeImportedFile(name: "recording.wav", samples: fixtureNoise(count: 256, seed: 1))
    let analysis = makeMockAnalysis(reference: fixture, recording: fixture)
    let service = MockNewMeasurementService(
        files: ["recording.wav": fixture],
        failingImports: ["broken.wav"],
        analysis: analysis
    )
    let model = NewMeasurementViewModel(service: service)

    model.selectFile(URL(fileURLWithPath: "/tmp/broken.wav"), role: .reference)
    await model.waitForCurrentOperation()

    #expect(model.referenceFile == nil)
    #expect(model.activeFailure?.code == .unreadableFile)
    model.recover()
    #expect(model.state == .idle)
}

@Test @MainActor
func successfulAnalysisMovesFromReadyToCompleted() async throws {
    let fixture = try makeImportedFile(name: "fixture.wav", samples: fixtureNoise(count: 512, seed: 2))
    let analysis = makeMockAnalysis(reference: fixture, recording: fixture, delaySamples: 64)
    let service = MockNewMeasurementService(
        files: ["reference.wav": fixture, "recording.wav": fixture],
        analysis: analysis
    )
    let model = NewMeasurementViewModel(service: service)
    await importBothFiles(into: model)

    #expect(model.state == .ready)
    model.analyze()
    #expect(model.state == .analyzing)
    #expect(model.result == nil)
    await model.waitForCurrentOperation()

    #expect(model.state == .completed)
    #expect(model.result?.assessment.delay?.sampleOffset.rawValue == 64)
    #expect(model.result?.presentation.estimatedDelayMilliseconds == 64.25 / 48)
}

@Test @MainActor
func cancellingAnalysisDoesNotPublishALateResult() async throws {
    let fixture = try makeImportedFile(name: "fixture.wav", samples: fixtureNoise(count: 512, seed: 3))
    let service = MockNewMeasurementService(
        files: ["reference.wav": fixture, "recording.wav": fixture],
        analysis: makeMockAnalysis(reference: fixture, recording: fixture),
        analysisDelayNanoseconds: 5_000_000_000
    )
    let model = NewMeasurementViewModel(service: service)
    await importBothFiles(into: model)

    model.analyze()
    #expect(model.state == .analyzing)
    model.cancel()
    try await Task.sleep(nanoseconds: 10_000_000)

    #expect(model.state == .cancelled)
    #expect(model.result == nil)
    model.recover()
    #expect(model.state == .ready)
}

@Test @MainActor
func replacingAFileImmediatelyInvalidatesCompletedResult() async throws {
    let fixture = try makeImportedFile(name: "fixture.wav", samples: fixtureNoise(count: 512, seed: 4))
    let replacement = try makeImportedFile(name: "replacement.wav", samples: fixtureNoise(count: 512, seed: 5))
    let service = MockNewMeasurementService(
        files: [
            "reference.wav": fixture,
            "recording.wav": fixture,
            "replacement.wav": replacement
        ],
        analysis: makeMockAnalysis(reference: fixture, recording: fixture)
    )
    let model = NewMeasurementViewModel(service: service)
    await importBothFiles(into: model)
    model.analyze()
    await model.waitForCurrentOperation()
    #expect(model.result != nil)

    model.selectFile(URL(fileURLWithPath: "/tmp/replacement.wav"), role: .reference)
    #expect(model.result == nil)
    #expect(model.state == .importing(.reference))
    await model.waitForCurrentOperation()

    #expect(model.state == .ready)
    #expect(model.referenceFile?.fileName == "replacement.wav")
    #expect(model.result == nil)
}

@Test @MainActor
func twoRapidAnalyzeRequestsStartOnlyOneServiceCall() async throws {
    let fixture = try makeImportedFile(name: "fixture.wav", samples: fixtureNoise(count: 512, seed: 6))
    let service = MockNewMeasurementService(
        files: ["reference.wav": fixture, "recording.wav": fixture],
        analysis: makeMockAnalysis(reference: fixture, recording: fixture),
        analysisDelayNanoseconds: 30_000_000
    )
    let model = NewMeasurementViewModel(service: service)
    await importBothFiles(into: model)

    model.analyze()
    model.analyze()
    await model.waitForCurrentOperation()

    let analysisCallCount = await service.analysisCallCount()
    #expect(analysisCallCount == 1)
    #expect(model.state == .completed)
}

@Test @MainActor
func qualityIssuesMapToStructuredResultWarningsAndCopyText() async throws {
    let fixture = try makeImportedFile(name: "fixture.wav", samples: fixtureNoise(count: 512, seed: 7))
    let issue = QualityIssue(
        code: .ambiguousPeak,
        severity: .warning,
        userDescription: "Two delay candidates are similarly strong.",
        technicalDescription: "Primary-to-secondary ratio is 1.01.",
        recommendedAction: "Use a non-repeating reference signal."
    )
    let analysis = makeMockAnalysis(
        reference: fixture,
        recording: fixture,
        qualityLevel: .questionable,
        issues: [issue]
    )
    let service = MockNewMeasurementService(
        files: ["reference.wav": fixture, "recording.wav": fixture],
        analysis: analysis
    )
    let model = NewMeasurementViewModel(service: service)
    await importBothFiles(into: model)
    model.analyze()
    await model.waitForCurrentOperation()

    let presentation = try #require(model.result?.presentation)
    #expect(presentation.warnings.map(\.code) == [.ambiguousPeak])
    #expect(presentation.warnings.first?.recommendation.contains("non-repeating") == true)
    #expect(presentation.structuredText.contains("warning[ambiguousPeak]"))
    #expect(presentation.structuredText.contains("estimated_delay_ms:"))
}

@Test func workflowErrorsMapToSpecificUserFacingCategories() {
    let cases: [(any Error, NewMeasurementFailureCode)] = [
        (AudioImportError.accessDenied(path: "/private/reference.wav"), .permissionLost),
        (AudioImportError.unsupportedContainer(extension: "mp3"), .unsupportedFormat),
        (
            NewMeasurementWorkflowError.sampleRateMismatch(
                reference: .hz44100,
                recording: .hz48000
            ),
            .sampleRateMismatch
        ),
        (
            NewMeasurementWorkflowError.signalTooShort(
                role: .reference,
                frameCount: 4,
                minimumFrames: 16
            ),
            .signalTooShort
        ),
        (
            NewMeasurementWorkflowError.invalidSearchRange(
                minimumMilliseconds: 100,
                maximumMilliseconds: 10
            ),
            .invalidSearchRange
        ),
        (NewMeasurementWorkflowError.noTrustworthyPeak, .noTrustworthyPeak),
        (CorrelationAnalysisError.fftLengthOverflow, .insufficientMemory),
        (CorrelationAnalysisError.cancelled, .cancelled)
    ]

    for (error, expectedCode) in cases {
        let failure = NewMeasurementFailure.from(error)
        #expect(failure.code == expectedCode)
        #expect(!failure.title.isEmpty)
        #expect(!failure.message.isEmpty)
        #expect(!failure.recoverySuggestion.isEmpty)
    }
}

@Test @MainActor
func realWAVImportPreprocessingAndAnalysisAgreeOnKnownDelay() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioLinkMacIntegration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let referenceSamples = fixtureNoise(count: 512, seed: 90).map { $0 * 0.45 }
    let knownDelay = 80
    let recordingSamples = [Float](repeating: 0, count: knownDelay)
        + referenceSamples
        + [Float](repeating: 0, count: 120)
    let referenceBuffer = try fixtureBuffer(referenceSamples)
    let recordingBuffer = try fixtureBuffer(recordingSamples)
    let referenceURL = directory.appendingPathComponent("reference.wav")
    let recordingURL = directory.appendingPathComponent("recording.wav")
    try WAVExporter().write(referenceBuffer, to: referenceURL, encoding: .pcmInt32)
    try WAVExporter().write(recordingBuffer, to: recordingURL, encoding: .pcmInt32)

    var configuration = NewMeasurementConfiguration.userDefault
    configuration.correlationMethod = .direct
    configuration.maximumDelayMilliseconds = 10
    configuration.removeDCOffset = false
    let model = NewMeasurementViewModel(
        service: LiveNewMeasurementService(),
        configuration: configuration
    )
    model.selectFile(referenceURL, role: .reference)
    await model.waitForCurrentOperation()
    model.selectFile(recordingURL, role: .recording)
    await model.waitForCurrentOperation()
    model.analyze()
    await model.waitForCurrentOperation()

    #expect(model.state == .completed)
    #expect(model.result?.assessment.delay?.sampleOffset.rawValue == Int64(knownDelay))
    #expect(abs((model.result?.presentation.estimatedDelayMilliseconds ?? 0) - Double(knownDelay) / 48) < 0.000_1)
    #expect(model.result?.assessment.correlation?.diagnostics?.implementation == .direct)
}

@Test
func visualizationRendererKeepsAnalysisMarkersAndPreparesOffMainThread() async throws {
    let reference = try makeImportedFile(name: "reference.wav", samples: fixtureNoise(count: 20_000, seed: 101))
    let recording = try makeImportedFile(name: "recording.wav", samples: fixtureNoise(count: 20_048, seed: 102))
    let analysis = makeMockAnalysis(reference: reference, recording: recording, delaySamples: 48)
    let renderer = MeasurementVisualizationRenderer(analysis: analysis)

    let waveform = try await renderer.waveform(
        viewport: renderer.initialWaveformViewport(alignment: .unaligned),
        alignment: .unaligned,
        pixelWidth: 1_000
    )
    let correlation = try await renderer.correlation(
        viewport: renderer.initialCorrelationViewport(),
        pixelWidth: 1_000
    )
    let detail = try await renderer.peakDetail()
    let preparedOnMain = await renderer.lastPreparationWasOnMainThread()

    #expect(waveform.reference.bins.count <= 2_048)
    #expect(waveform.recording.bins.count <= 2_048)
    #expect(waveform.markers.first?.position == 48.25)
    #expect(correlation.markers.contains { $0.kind == .primaryPeak && $0.position == 48.25 })
    #expect(correlation.markers.filter { $0.kind == .searchBoundary }.count == 2)
    #expect(detail.integerPeakLag == 48)
    #expect(detail.fractionalPeakLag == 48.25)
    #expect(preparedOnMain == false)
}

@Test
func alignedWaveformOffsetsRecordingByEstimatedDelay() async throws {
    let file = try makeImportedFile(name: "fixture.wav", samples: fixtureNoise(count: 4_096, seed: 103))
    let renderer = MeasurementVisualizationRenderer(
        analysis: makeMockAnalysis(reference: file, recording: file, delaySamples: 64)
    )
    let data = try await renderer.waveform(
        viewport: renderer.initialWaveformViewport(alignment: .aligned),
        alignment: .aligned,
        pixelWidth: 800
    )

    #expect(data.alignmentMode == .aligned)
    #expect(data.recording.plotOffsetSamples == -64.25)
    #expect(data.markers.first?.position == 0)
}

@Test
func PNGExporterProducesRequestedDimensionsWithoutFilePaths() async throws {
    let secretPath = "/private/customer/audio/reference.wav"
    let file = try makeImportedFile(name: secretPath, samples: fixtureNoise(count: 2_048, seed: 104))
    let renderer = MeasurementVisualizationRenderer(
        analysis: makeMockAnalysis(reference: file, recording: file)
    )
    let renderData = try await renderer.waveform(
        viewport: renderer.initialWaveformViewport(alignment: .unaligned),
        alignment: .unaligned,
        pixelWidth: 800
    )
    let data = try PlotPNGExporter().pngData(
        document: PlotExportDocument(
            title: "AudioLink Lab — Waveforms",
            content: .waveform(renderData),
            appearance: .dark
        ),
        width: 800,
        height: 420
    )
    let bitmap = try #require(NSBitmapImageRep(data: data))

    #expect(bitmap.pixelsWide == 800)
    #expect(bitmap.pixelsHigh == 420)
    #expect(!data.contains(Data(secretPath.utf8)))
}

@Test
func millionSampleDisplayPreparationStaysPixelBounded() async throws {
    let samples = fixtureNoise(count: 1_000_000, seed: 105)
    let file = try makeImportedFile(name: "long.wav", samples: samples)
    let renderer = MeasurementVisualizationRenderer(
        analysis: makeMockAnalysis(reference: file, recording: file)
    )
    let data = try await renderer.waveform(
        viewport: renderer.initialWaveformViewport(alignment: .unaligned),
        alignment: .unaligned,
        pixelWidth: 1_200
    )
    let preparedOnMain = await renderer.lastPreparationWasOnMainThread()

    #expect(data.reference.bins.count <= 4_096)
    #expect(data.recording.bins.count <= 4_096)
    #expect(preparedOnMain == false)
}

@Test @MainActor
func completedAnalysisPersistsResultsOnlyWithoutPathsOrAudio() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioLinkHistoryAppTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteMeasurementRepository(
        databaseURL: directory.appendingPathComponent("history.sqlite")
    )
    let fixture = try makeImportedFile(name: "private-recording.wav", samples: fixtureNoise(count: 512, seed: 110))
    let analysis = makeMockAnalysis(reference: fixture, recording: fixture)
    let service = MockNewMeasurementService(
        files: ["reference.wav": fixture, "recording.wav": fixture],
        analysis: analysis
    )
    let persistence = LiveMeasurementHistoryPersistence(
        repository: repository,
        audioContainerURL: directory
    )
    let model = NewMeasurementViewModel(
        service: service,
        historyPersistence: persistence
    )
    await importBothFiles(into: model)
    model.analyze()
    await model.waitForCurrentOperation()
    await model.waitForHistorySave()

    guard case .saved = model.historySaveState else {
        Issue.record("Expected completed analysis to save to history")
        return
    }
    let page = try await repository.runs(matching: .init())
    #expect(page.totalCount == 1)
    let stored = try #require(try await repository.run(id: analysis.id))
    #expect(stored.referenceFile.fileName == "private-recording.wav")
    #expect(stored.referenceFile.securityScopedBookmark == nil)
    #expect(stored.referenceFile.audioCopyRelativePath == nil)
    #expect(stored.correlation?.sequence != nil)
    #expect(!stored.chartCache.waveformAvailable)
    #expect(stored.chartCache.waveformUnavailableReason?.contains("raw audio") == true)
}

@Test @MainActor
func doNotSavePolicyAndStorageFailureNeverDiscardAnalysisResult() async throws {
    let fixture = try makeImportedFile(name: "fixture.wav", samples: fixtureNoise(count: 512, seed: 111))
    let analysis = makeMockAnalysis(reference: fixture, recording: fixture)
    let repository = try SQLiteMeasurementRepository(
        databaseURL: URL(fileURLWithPath: "/tmp/AudioLink-in-memory-placeholder.sqlite"),
        inMemory: true
    )
    let persistence = LiveMeasurementHistoryPersistence(repository: repository, audioContainerURL: nil)
    let service = MockNewMeasurementService(
        files: ["reference.wav": fixture, "recording.wav": fixture],
        analysis: analysis
    )
    let skippedModel = NewMeasurementViewModel(
        service: service,
        historyPersistence: persistence,
        savePolicy: .doNotSave
    )
    await importBothFiles(into: skippedModel)
    skippedModel.analyze()
    await skippedModel.waitForCurrentOperation()
    await skippedModel.waitForHistorySave()
    #expect(skippedModel.state == .completed)
    #expect(skippedModel.historySaveState == .skipped)
    #expect(try await repository.repositoryInfo().runCount == 0)

    let unavailable = UnavailableMeasurementRepository(
        error: .unableToOpenDatabase(message: "test unavailable")
    )
    let failingModel = NewMeasurementViewModel(
        service: service,
        historyPersistence: LiveMeasurementHistoryPersistence(
            repository: unavailable,
            audioContainerURL: nil
        )
    )
    await importBothFiles(into: failingModel)
    failingModel.analyze()
    await failingModel.waitForCurrentOperation()
    await failingModel.waitForHistorySave()
    #expect(failingModel.state == .completed)
    #expect(failingModel.result != nil)
    guard case .failed = failingModel.historySaveState else {
        Issue.record("Expected an independent history-save failure")
        return
    }
}

@Test @MainActor
func explicitAudioCopyPolicyStoresOnlyRelativeContainerReferences() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioLinkHistoryCopies-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let referenceURL = directory.appendingPathComponent("source-reference.wav")
    let recordingURL = directory.appendingPathComponent("source-recording.wav")
    try Data([1, 2, 3, 4]).write(to: referenceURL)
    try Data([5, 6, 7, 8]).write(to: recordingURL)
    let reference = try makeImportedFile(url: referenceURL, samples: fixtureNoise(count: 512, seed: 112))
    let recording = try makeImportedFile(url: recordingURL, samples: fixtureNoise(count: 512, seed: 113))
    let analysis = makeMockAnalysis(reference: reference, recording: recording)
    let repository = try SQLiteMeasurementRepository(
        databaseURL: directory.appendingPathComponent("history.sqlite")
    )
    let persistence = LiveMeasurementHistoryPersistence(
        repository: repository,
        audioContainerURL: directory
    )

    _ = try await persistence.persist(
        analysis: analysis,
        configuration: .userDefault,
        policy: .audioCopies
    )
    let stored = try #require(try await repository.run(id: analysis.id))
    let referencePath = try #require(stored.referenceFile.audioCopyRelativePath)
    let recordingPath = try #require(stored.recordingFile.audioCopyRelativePath)
    #expect(!referencePath.hasPrefix("/"))
    #expect(!recordingPath.hasPrefix("/"))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(referencePath).path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(recordingPath).path))
    #expect(stored.referenceFile.securityScopedBookmark == nil)
    #expect(stored.chartCache.waveformAvailable)

    try await repository.deleteRun(id: analysis.id)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(referencePath).path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(recordingPath).path))
}

@Test @MainActor
func explicitBookmarkPolicyRetainsBookmarksWithoutAudioCopies() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioLinkHistoryBookmarks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let referenceURL = directory.appendingPathComponent("bookmark-reference.wav")
    let recordingURL = directory.appendingPathComponent("bookmark-recording.wav")
    try Data([1, 2, 3]).write(to: referenceURL)
    try Data([4, 5, 6]).write(to: recordingURL)
    let reference = try makeImportedFile(url: referenceURL, samples: fixtureNoise(count: 512, seed: 114))
    let recording = try makeImportedFile(url: recordingURL, samples: fixtureNoise(count: 512, seed: 115))
    let analysis = makeMockAnalysis(reference: reference, recording: recording)
    let repository = try SQLiteMeasurementRepository(
        databaseURL: directory.appendingPathComponent("history.sqlite")
    )
    let persistence = LiveMeasurementHistoryPersistence(repository: repository, audioContainerURL: directory)

    _ = try await persistence.persist(
        analysis: analysis,
        configuration: .userDefault,
        policy: .securityScopedBookmarks
    )
    let stored = try #require(try await repository.run(id: analysis.id))
    #expect(stored.referenceFile.securityScopedBookmark?.isEmpty == false)
    #expect(stored.recordingFile.securityScopedBookmark?.isEmpty == false)
    #expect(stored.referenceFile.audioCopyRelativePath == nil)
    #expect(!stored.chartCache.waveformAvailable)
}

@Test @MainActor
func historyViewModelSearchesUpdatesComparesExportsAndDeletes() async throws {
    let repository = try SQLiteMeasurementRepository(
        databaseURL: URL(fileURLWithPath: "/tmp/AudioLink-in-memory-placeholder.sqlite"),
        inMemory: true
    )
    let persistence = LiveMeasurementHistoryPersistence(repository: repository, audioContainerURL: nil)
    var runIDs: [UUID] = []
    for index in 0..<3 {
        let reference = try makeImportedFile(name: "reference-\(index).wav", samples: fixtureNoise(count: 512, seed: UInt64(120 + index)))
        let recording = try makeImportedFile(name: "recording-\(index).wav", samples: fixtureNoise(count: 512, seed: UInt64(130 + index)))
        let analysis = makeMockAnalysis(
            reference: reference,
            recording: recording,
            delaySamples: Int64(48 + index),
            qualityLevel: index == 2 ? .questionable : .good
        )
        runIDs.append(analysis.id)
        let sessionID = try #require(
            try await persistence.persist(
                analysis: analysis,
                configuration: .userDefault,
                policy: .resultsOnly
            )
        )
        if index == 1 {
            try await repository.updateSession(id: sessionID, name: "Updated bench", notes: "special note")
        }
    }

    let model = MeasurementHistoryViewModel(repository: repository, pageSize: 2)
    await model.reload()
    #expect(model.runs.count == 2)
    #expect(model.totalCount == 3)
    #expect(model.hasMore)
    await model.loadMore()
    #expect(model.runs.count == 3)

    model.searchText = "special note"
    await model.reload()
    #expect(model.runs.count == 1)
    #expect(model.runs[0].sessionName == "Updated bench")

    model.searchText = ""
    model.qualityFilter = MeasurementQualityLevel.good.rawValue
    await model.reload()
    #expect(model.totalCount == 2)
    model.qualityFilter = "all"
    await model.reload()
    await model.loadMore()

    model.selectedRunIDs = Set(runIDs.prefix(2))
    await model.compareSelected()
    #expect(model.comparison?.entries.count == 2)
    let exported = try await model.exportSelectedJSON()
    #expect(!exported.isEmpty)
    #expect(!exported.contains(Data("/Users/".utf8)))

    await model.deleteSelected()
    #expect(model.totalCount == 1)
}

private actor MockNewMeasurementService: NewMeasurementServicing {
    private let files: [String: ImportedAudioFile]
    private let failingImports: Set<String>
    private let analysis: NewMeasurementAnalysis
    private let analysisDelayNanoseconds: UInt64
    private var analysisCalls = 0

    init(
        files: [String: ImportedAudioFile],
        failingImports: Set<String> = [],
        analysis: NewMeasurementAnalysis,
        analysisDelayNanoseconds: UInt64 = 0
    ) {
        self.files = files
        self.failingImports = failingImports
        self.analysis = analysis
        self.analysisDelayNanoseconds = analysisDelayNanoseconds
    }

    func importAudio(at url: URL) async throws -> ImportedAudioFile {
        if failingImports.contains(url.lastPathComponent) {
            throw AudioImportError.corruptedFile(reason: "Mock corrupt WAV")
        }
        guard let file = files[url.lastPathComponent] else {
            throw AudioImportError.fileNotFound(url)
        }
        return ImportedAudioFile(
            fileURL: url,
            fileName: url.lastPathComponent,
            originalFormat: file.originalFormat,
            audio: file.audio,
            analysis: file.analysis,
            metadata: file.metadata,
            preprocessingLog: file.preprocessingLog
        )
    }

    func analyze(
        reference: ImportedAudioFile,
        recording: ImportedAudioFile,
        configuration: NewMeasurementConfiguration
    ) async throws -> NewMeasurementAnalysis {
        analysisCalls += 1
        if analysisDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: analysisDelayNanoseconds)
        }
        try Task.checkCancellation()
        return analysis
    }

    func analysisCallCount() -> Int { analysisCalls }
}

@MainActor
private func importBothFiles(into model: NewMeasurementViewModel) async {
    model.selectFile(URL(fileURLWithPath: "/tmp/reference.wav"), role: .reference)
    await model.waitForCurrentOperation()
    model.selectFile(URL(fileURLWithPath: "/tmp/recording.wav"), role: .recording)
    await model.waitForCurrentOperation()
}

private func makeMockAnalysis(
    reference: ImportedAudioFile,
    recording: ImportedAudioFile,
    analysisID: UUID = UUID(),
    delaySamples: Int64 = 48,
    qualityLevel: MeasurementQualityLevel = .good,
    issues: [QualityIssue] = []
) -> NewMeasurementAnalysis {
    let delay = DelayEstimate(
        sampleOffset: SampleCount(rawValue: delaySamples),
        sampleRate: .hz48000,
        confidence: 0.91,
        fractionalSampleOffset: Double(delaySamples) + 0.25,
        peakAmplitude: 0.96,
        peakToSidelobeRatio: 12,
        isReliable: true
    )
    let peak = CorrelationPeak(
        lag: SampleCount(rawValue: delaySamples),
        fractionalLag: Double(delaySamples) + 0.25,
        value: 0.96,
        overlapCount: SampleCount(rawValue: Int64(reference.frameCount))
    )
    let diagnostics = AnalysisDiagnostics(
        implementation: .fft,
        validity: issues.isEmpty ? .valid : .ambiguous,
        validLagRange: SampleLagRange(minimum: -511, maximum: 511),
        searchedLagRange: SampleLagRange(minimum: 0, maximum: 511),
        searchRangeWasClamped: false,
        peakAtSearchBoundary: false,
        referenceRMS: Double(reference.rootMeanSquare),
        observedRMS: Double(recording.rootMeanSquare),
        minimumOverlapCount: SampleCount(rawValue: 256),
        fftLength: 1_024,
        estimatedWorkingSetBytes: 64_000,
        interpolationStatus: .applied
    )
    let correlation = CorrelationResult(
        peakOffset: SampleCount(rawValue: delaySamples),
        normalizedPeak: 0.96,
        peakToSidelobeRatio: 12,
        confidence: 0.91,
        primaryPeak: peak,
        sequence: mockCorrelationSequence(peakLag: delaySamples),
        diagnostics: diagnostics
    )
    let confidence = qualityLevel == .questionable ? 0.6 : 0.8
    let quality = MeasurementQuality(
        level: qualityLevel,
        confidence: ConfidenceScore(value: confidence, components: []),
        summary: issues.isEmpty ? "The delay match is clear." : "More than one delay may be plausible.",
        metrics: [],
        issues: issues,
        peakAmbiguity: PeakAmbiguity(
            candidates: [peak],
            primaryToSecondaryRatio: nil,
            hasSimilarPeaks: !issues.isEmpty,
            peakSpacings: [],
            periodicInterval: nil,
            explanation: issues.isEmpty ? "One dominant peak." : "Multiple similar peaks."
        ),
        signal: SignalQualityAnalysis(
            referenceRMS: Double(reference.rootMeanSquare),
            observedRMS: Double(recording.rootMeanSquare),
            signalToNoiseDecibels: 30,
            clippingRatio: 0,
            dcOffsetMagnitude: 0,
            referenceCoverageRatio: 1,
            isPolarityInverted: false,
            appearsTruncated: false,
            channelsConsistent: nil,
            channelDelaySpreadSamples: nil,
            channelPeakSpread: nil
        ),
        delayDiagnostics: DelayEstimateDiagnostics(
            selectedDelay: delay,
            candidatePeaks: [peak],
            peakWidthSamples: 2,
            localPeakSharpness: 0.5,
            searchBoundaryDistance: SampleCount(rawValue: 100),
            channelResults: []
        ),
        shouldRemeasure: qualityLevel == .questionable
    )
    let assessment = QualityAssessedMeasurement(
        delay: delay,
        correlation: correlation,
        quality: quality
    )
    return NewMeasurementAnalysis(
        id: analysisID,
        preparedReference: reference,
        preparedRecording: recording,
        analysisChannel: 0,
        assessment: assessment,
        presentation: NewMeasurementResultPresentation(assessment: assessment)
    )
}

private func mockCorrelationSequence(peakLag: Int64) -> CorrelationSequence {
    let firstLag: Int64 = -511
    var values = [Float](repeating: 0.005, count: 1_023)
    let peakIndex = Int(peakLag - firstLag)
    if peakIndex > 0, peakIndex + 1 < values.count {
        values[peakIndex - 1] = 0.76
        values[peakIndex] = 0.96
        values[peakIndex + 1] = 0.88
    }
    return CorrelationSequence(firstLag: firstLag, values: values)
}

private func makeImportedFile(name: String, samples: [Float]) throws -> ImportedAudioFile {
    let buffer = try fixtureBuffer(samples)
    return ImportedAudioFile(
        fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
        fileName: name,
        originalFormat: AudioFileFormatDescription(
            container: .wav,
            encoding: .ieeeFloat,
            sampleRate: .hz48000,
            channelCount: 1,
            bitDepth: 32,
            isInterleaved: true,
            isBigEndian: false,
            formatIdentifier: "WAVE_FORMAT_IEEE_FLOAT"
        ),
        audio: buffer,
        analysis: AudioMetricsAnalyzer().analyze(buffer)
    )
}

private func makeImportedFile(url: URL, samples: [Float]) throws -> ImportedAudioFile {
    let source = try makeImportedFile(name: url.lastPathComponent, samples: samples)
    return ImportedAudioFile(
        fileURL: url,
        fileName: url.lastPathComponent,
        originalFormat: source.originalFormat,
        audio: source.audio,
        analysis: source.analysis,
        metadata: source.metadata,
        preprocessingLog: source.preprocessingLog
    )
}

private func fixtureBuffer(_ samples: [Float]) throws -> AudioSampleBuffer {
    try AudioSampleBuffer(
        samples: samples,
        format: AudioFormatDescriptor(
            sampleRate: .hz48000,
            channelCount: 1,
            bitDepth: 32,
            isInterleaved: false
        )
    )
}

private func fixtureNoise(count: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(Double(state & 0x00FF_FFFF) / Double(0x0080_0000) - 1)
    }
}
