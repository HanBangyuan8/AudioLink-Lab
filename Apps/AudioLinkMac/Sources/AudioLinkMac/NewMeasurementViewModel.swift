import AudioLinkDSP
import AudioLinkStorage
import Combine
import Foundation

enum MeasurementHistorySaveState: Equatable, Sendable {
    case idle
    case saving
    case saved(sessionID: UUID)
    case skipped
    case failed(message: String)
}

@MainActor
final class NewMeasurementViewModel: ObservableObject {
    @Published private(set) var state: NewMeasurementFeatureState = .idle
    @Published private(set) var referenceFile: ImportedAudioFile?
    @Published private(set) var recordingFile: ImportedAudioFile?
    @Published private(set) var result: NewMeasurementAnalysis?
    @Published var savePolicy: MeasurementSavePolicy
    @Published private(set) var historySaveState = MeasurementHistorySaveState.idle
    @Published var configuration: NewMeasurementConfiguration {
        didSet {
            guard configuration != oldValue, !suppressesConfigurationInvalidation else { return }
            invalidateResultAndCancelOperation()
            state = filesAreReady ? .ready : .idle
        }
    }

    private let service: any NewMeasurementServicing
    private let historyPersistence: (any MeasurementHistoryPersisting)?
    private var operationTask: Task<Void, Never>?
    private var historySaveTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var suppressesConfigurationInvalidation = false

    init(
        service: any NewMeasurementServicing = LiveNewMeasurementService(),
        configuration: NewMeasurementConfiguration = .userDefault,
        historyPersistence: (any MeasurementHistoryPersisting)? = nil,
        savePolicy: MeasurementSavePolicy = .resultsOnly
    ) {
        self.service = service
        self.historyPersistence = historyPersistence
        self.configuration = configuration
        self.savePolicy = savePolicy
    }

    deinit {
        operationTask?.cancel()
        historySaveTask?.cancel()
    }

    var filesAreReady: Bool {
        referenceFile != nil && recordingFile != nil
    }

    var canAnalyze: Bool {
        filesAreReady && !state.isBusy
    }

    var activeFailure: NewMeasurementFailure? {
        guard case let .failed(failure) = state else { return nil }
        return failure
    }

    var suggestedOpenRole: NewMeasurementFileRole {
        if referenceFile == nil { return .reference }
        if recordingFile == nil { return .recording }
        return .reference
    }

    func file(for role: NewMeasurementFileRole) -> ImportedAudioFile? {
        switch role {
        case .reference: referenceFile
        case .recording: recordingFile
        }
    }

    func selectFile(_ url: URL, role: NewMeasurementFileRole) {
        let generation = beginOperation()
        clearFile(role)
        result = nil
        state = .importing(role)
        let service = self.service

        operationTask = Task { [weak self] in
            do {
                let imported = try await service.importAudio(at: url)
                try Task.checkCancellation()
                guard let self, self.operationGeneration == generation else { return }
                self.install(imported, role: role)
                self.state = self.filesAreReady ? .ready : .idle
                self.operationTask = nil
            } catch {
                guard let self, self.operationGeneration == generation else { return }
                let failure = NewMeasurementFailure.from(error)
                self.state = failure.code == .cancelled ? .cancelled : .failed(failure)
                self.operationTask = nil
            }
        }
    }

    func removeFile(_ role: NewMeasurementFileRole) {
        invalidateResultAndCancelOperation()
        clearFile(role)
        state = filesAreReady ? .ready : .idle
    }

    func analyze() {
        guard !state.isBusy else { return }
        guard let referenceFile, let recordingFile else {
            state = .failed(
                NewMeasurementFailure(
                    code: .unreadableFile,
                    title: "Two audio files are required",
                    message: "Select both a reference WAV and a recording WAV before analysis.",
                    recoverySuggestion: "Choose the missing file, then select Analyze.",
                    technicalContext: nil
                )
            )
            return
        }
        do {
            try configuration.validate(reference: referenceFile, recording: recordingFile)
        } catch {
            state = .failed(NewMeasurementFailure.from(error))
            result = nil
            return
        }

        let generation = beginOperation()
        let requestedConfiguration = configuration
        let service = self.service
        result = nil
        state = .analyzing

        operationTask = Task { [weak self] in
            do {
                let analysis = try await service.analyze(
                    reference: referenceFile,
                    recording: recordingFile,
                    configuration: requestedConfiguration
                )
                try Task.checkCancellation()
                guard let self, self.operationGeneration == generation else { return }
                self.result = analysis
                self.state = .completed
                self.operationTask = nil
                self.beginHistorySave(
                    analysis: analysis,
                    configuration: requestedConfiguration,
                    generation: generation
                )
            } catch {
                guard let self, self.operationGeneration == generation else { return }
                let failure = NewMeasurementFailure.from(error)
                self.result = nil
                self.state = failure.code == .cancelled ? .cancelled : .failed(failure)
                self.operationTask = nil
            }
        }
    }

    func cancel() {
        guard state.isBusy else { return }
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        result = nil
        state = .cancelled
    }

    func recover() {
        guard case .failed = state else {
            if case .cancelled = state {
                state = filesAreReady ? .ready : .idle
            }
            return
        }
        state = filesAreReady ? .ready : .idle
    }

    func report(_ error: any Error) {
        invalidateResultAndCancelOperation()
        let failure = NewMeasurementFailure.from(error)
        state = failure.code == .cancelled ? .cancelled : .failed(failure)
    }

    func retryHistorySave() {
        guard let result, case .completed = state else { return }
        beginHistorySave(
            analysis: result,
            configuration: configuration,
            generation: operationGeneration
        )
    }

    func preprocessingStatus(for role: NewMeasurementFileRole) -> [String] {
        if let result, case .completed = state {
            let processed = role == .reference ? result.preparedReference : result.preparedRecording
            return processed.preprocessingSummary.isEmpty
                ? ["No preprocessing was applied"]
                : processed.preprocessingSummary
        }

        var operations: [String] = []
        if configuration.downmixToMono {
            operations.append("Downmix to mono")
        } else {
            let channel = role == .reference
                ? configuration.referenceChannel
                : configuration.recordingChannel
            operations.append("Analyze channel \(channel + 1)")
        }
        if configuration.removeDCOffset { operations.append("Remove DC offset") }
        if configuration.highPassEnabled {
            operations.append("High-pass at \(configuration.highPassCutoffHertz.formatted()) Hz")
        }
        switch configuration.normalization {
        case .none: break
        case .peak: operations.append("Peak normalize to −1 dBFS")
        case .rms: operations.append("RMS normalize to −18 dBFS")
        }
        if role == .recording, configuration.polarityHandling == .invertRecording {
            operations.append("Invert polarity")
        }
        switch (role, configuration.resamplingStrategy) {
        case (.recording, .recordingToReference):
            operations.append("Match reference sample rate if needed")
        case (.reference, .referenceToRecording):
            operations.append("Match recording sample rate if needed")
        default:
            break
        }
        return operations
    }

    func waitForCurrentOperation() async {
        let task = operationTask
        await task?.value
    }

    func waitForHistorySave() async {
        let task = historySaveTask
        await task?.value
    }

    private func beginOperation() -> UInt64 {
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        return operationGeneration
    }

    private func invalidateResultAndCancelOperation() {
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        historySaveTask?.cancel()
        historySaveTask = nil
        result = nil
        historySaveState = .idle
    }

    private func clearFile(_ role: NewMeasurementFileRole) {
        switch role {
        case .reference: referenceFile = nil
        case .recording: recordingFile = nil
        }
    }

    private func install(_ file: ImportedAudioFile, role: NewMeasurementFileRole) {
        switch role {
        case .reference:
            referenceFile = file
        case .recording:
            recordingFile = file
        }
        suppressesConfigurationInvalidation = true
        if let referenceFile {
            configuration.referenceChannel = min(
                configuration.referenceChannel,
                max(0, referenceFile.channelCount - 1)
            )
        }
        if let recordingFile {
            configuration.recordingChannel = min(
                configuration.recordingChannel,
                max(0, recordingFile.channelCount - 1)
            )
        }
        suppressesConfigurationInvalidation = false
    }

    private func beginHistorySave(
        analysis: NewMeasurementAnalysis,
        configuration: NewMeasurementConfiguration,
        generation: UInt64
    ) {
        historySaveTask?.cancel()
        guard let historyPersistence else {
            historySaveState = savePolicy == .doNotSave ? .skipped : .idle
            return
        }
        let policy = savePolicy
        if policy == .doNotSave {
            historySaveState = .skipped
            return
        }
        historySaveState = .saving
        historySaveTask = Task { [weak self] in
            do {
                let sessionID = try await historyPersistence.persist(
                    analysis: analysis,
                    configuration: configuration,
                    policy: policy
                )
                try Task.checkCancellation()
                guard let self, self.operationGeneration == generation else { return }
                if let sessionID {
                    self.historySaveState = .saved(sessionID: sessionID)
                } else {
                    self.historySaveState = .skipped
                }
                self.historySaveTask = nil
            } catch is CancellationError {
                guard let self, self.operationGeneration == generation else { return }
                self.historySaveState = .idle
                self.historySaveTask = nil
            } catch {
                guard let self, self.operationGeneration == generation else { return }
                if let storageError = error as? MeasurementStorageError {
                    self.historySaveState = .failed(message: storageError.userFacingDescription)
                } else {
                    self.historySaveState = .failed(message: "The measurement result could not be saved to local history.")
                }
                self.historySaveTask = nil
            }
        }
    }
}
