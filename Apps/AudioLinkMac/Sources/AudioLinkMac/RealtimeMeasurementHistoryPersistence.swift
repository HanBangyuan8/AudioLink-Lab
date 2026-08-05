import AudioLinkCore
import AudioLinkDSP
import AudioLinkRealtime
import AudioLinkStorage
import Foundation

actor LiveRealtimeMeasurementHistoryPersistence: RealtimeMeasurementSaving {
    static let algorithmVersion = AudioLinkReleaseMetadata.algorithmVersion
    private let repository: any MeasurementRepository

    init(repository: any MeasurementRepository) {
        self.repository = repository
    }

    func save(result: RealtimeMeasurementResult) async throws -> UUID? {
        let sessionID = result.configuration.measurementGroupID ?? UUID()
        let reference = storedFile(result.preparedReference, role: .reference)
        let recording = storedFile(result.preparedRecording, role: .recording)
        let diagnosticsJSON: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            diagnosticsJSON = String(decoding: try encoder.encode(result.diagnostics), as: UTF8.self)
        } catch {
            throw MeasurementStorageError.encodingFailed(
                type: "AudioEngineDiagnostics",
                message: error.localizedDescription
            )
        }
        let run = MeasurementHistoryRun(
            id: result.id,
            sessionID: sessionID,
            createdAt: result.startedAt,
            completedAt: result.completedAt,
            referenceFile: reference,
            recordingFile: recording,
            delayEstimate: result.assessment.delay,
            calibration: result.assessment.calibration,
            correlation: result.assessment.correlation,
            quality: result.assessment.quality,
            processingSteps: storedProcessingSteps(result.preparedRecording) + [
                StoredProcessingStep(
                    role: .recording,
                    sequence: result.preparedRecording.preprocessingLog.count,
                    operationCode: "audioEngineDiagnostics",
                    summary: diagnosticsJSON,
                    inputFrameCount: result.preparedRecording.frameCount,
                    outputFrameCount: result.preparedRecording.frameCount
                )
            ],
            chartCache: StoredChartCacheMetadata(
                correlationSequenceAvailable: result.assessment.correlation?.sequence != nil,
                correlationSampleCount: result.assessment.correlation?.sequence?.values.count ?? 0,
                waveformAvailable: false,
                waveformUnavailableReason: "Real-time audio is not retained by the default results-only privacy policy."
            ),
            notes: runNotes(result.configuration)
        )
        let configurationPayload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            configurationPayload = try encoder.encode(result.configuration)
        } catch {
            throw MeasurementStorageError.encodingFailed(
                type: "RealtimeMeasurementConfiguration",
                message: error.localizedDescription
            )
        }
        if try await repository.session(id: sessionID) != nil {
            try await repository.appendRun(run, toSession: sessionID)
            return sessionID
        }
        let session = MeasurementHistorySession(
            id: sessionID,
            createdAt: result.startedAt,
            updatedAt: result.completedAt,
            name: sessionName(result.configuration),
            measurementType: .liveAudio,
            savePolicy: .resultsOnly,
            configurationPayload: configurationPayload,
            configurationSummary: configurationSummary(result.configuration),
            inputDevice: result.configuration.route.inputDevice.descriptor,
            outputDevice: result.configuration.route.outputDevice.descriptor,
            appVersion: appVersion,
            algorithmVersion: Self.algorithmVersion,
            runs: [run]
        )
        try await repository.saveSession(session)
        return sessionID
    }

    private func sessionName(_ configuration: RealtimeMeasurementConfiguration) -> String {
        let route = "\(configuration.route.outputDevice.name) → \(configuration.route.inputDevice.name)"
        return configuration.measurementGroupID == nil ? route : "Repeated: \(route)"
    }

    private func runNotes(_ configuration: RealtimeMeasurementConfiguration) -> String {
        guard let sequence = configuration.planRunSequence else { return "Standalone real-time run" }
        return configuration.isWarmUpRun
            ? "Repeated measurement warm-up step \(sequence)"
            : "Repeated measurement run step \(sequence)"
    }

    private func storedFile(
        _ file: ImportedAudioFile,
        role: StoredFileRole
    ) -> StoredAudioFileMetadata {
        StoredAudioFileMetadata(
            role: role,
            privacyIdentifier: UUID().uuidString,
            fileName: file.fileName,
            container: file.originalFormat.container.rawValue,
            encoding: file.originalFormat.encoding.rawValue,
            format: file.internalFormat,
            frameCount: file.frameCount,
            durationSeconds: file.duration.value,
            peakMagnitude: Double(file.peakMagnitude),
            rootMeanSquare: Double(file.rootMeanSquare),
            clippingSampleCount: file.clippingSampleCount,
            dcOffset: Double(file.dcOffset)
        )
    }

    private func storedProcessingSteps(_ file: ImportedAudioFile) -> [StoredProcessingStep] {
        file.preprocessingLog.map { entry in
            StoredProcessingStep(
                role: .recording,
                sequence: entry.sequence,
                operationCode: String(describing: entry.operation),
                summary: entry.operation.summary,
                inputFrameCount: entry.inputFrameCount,
                outputFrameCount: entry.outputFrameCount
            )
        }
    }

    private func configurationSummary(_ configuration: RealtimeMeasurementConfiguration) -> [String: String] {
        [
            "inputDevice": configuration.route.inputDevice.name,
            "outputDevice": configuration.route.outputDevice.name,
            "inputChannel": String(configuration.route.inputChannel + 1),
            "outputChannel": String(configuration.route.outputChannel + 1),
            "sampleRate": String(configuration.route.sampleRate.hertz),
            "bufferFrames": String(configuration.route.bufferFrameCount),
            "signalKind": configuration.signal.kind.rawValue,
            "signalDurationSeconds": String(configuration.signal.duration.value),
            "signalAmplitude": String(configuration.signal.amplitude),
            "preRollSeconds": String(configuration.preRoll.value),
            "postRollSeconds": String(configuration.postRoll.value),
            "correlationMethod": configuration.correlation.method.rawValue,
            "measurementMode": configuration.measurementGroupID == nil ? "standalone" : "repeated",
            "planRunSequence": configuration.planRunSequence.map(String.init) ?? "",
            "isWarmUpRun": String(configuration.isWarmUpRun)
        ]
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
