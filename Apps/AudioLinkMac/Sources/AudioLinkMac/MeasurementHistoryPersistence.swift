import AudioLinkCore
import AudioLinkDSP
import AudioLinkStorage
import Foundation

protocol MeasurementHistoryPersisting: Sendable {
    func persist(
        analysis: NewMeasurementAnalysis,
        configuration: NewMeasurementConfiguration,
        policy: MeasurementSavePolicy
    ) async throws -> UUID?
}

actor LiveMeasurementHistoryPersistence: MeasurementHistoryPersisting {
    static let algorithmVersion = AudioLinkReleaseMetadata.algorithmVersion

    private let repository: any MeasurementRepository
    private let audioContainerURL: URL?
    private let fileManager: FileManager

    init(
        repository: any MeasurementRepository,
        audioContainerURL: URL?,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.audioContainerURL = audioContainerURL
        self.fileManager = fileManager
    }

    func persist(
        analysis: NewMeasurementAnalysis,
        configuration: NewMeasurementConfiguration,
        policy: MeasurementSavePolicy
    ) async throws -> UUID? {
        guard policy != .doNotSave else { return nil }
        let sessionID = UUID()
        let now = Date()
        var copiedRelativePaths: [String] = []
        let reference: StoredAudioFileMetadata
        let recording: StoredAudioFileMetadata
        do {
            reference = try storedFile(
                analysis.preparedReference,
                role: .reference,
                runID: analysis.id,
                policy: policy,
                copiedRelativePaths: &copiedRelativePaths
            )
            recording = try storedFile(
                analysis.preparedRecording,
                role: .recording,
                runID: analysis.id,
                policy: policy,
                copiedRelativePaths: &copiedRelativePaths
            )
        } catch {
            removeUncommittedCopies(copiedRelativePaths)
            throw error
        }
        let processingSteps = storedProcessingSteps(
            analysis.preparedReference,
            role: .reference
        ) + storedProcessingSteps(
            analysis.preparedRecording,
            role: .recording
        )
        let sequenceCount = analysis.assessment.correlation?.sequence?.values.count ?? 0
        let retainsAudio = policy == .audioCopies
        let run = MeasurementHistoryRun(
            id: analysis.id,
            sessionID: sessionID,
            createdAt: now,
            completedAt: now,
            referenceFile: reference,
            recordingFile: recording,
            delayEstimate: analysis.assessment.delay,
            calibration: analysis.assessment.calibration,
            correlation: analysis.assessment.correlation,
            quality: analysis.assessment.quality,
            processingSteps: processingSteps,
            chartCache: StoredChartCacheMetadata(
                correlationSequenceAvailable: sequenceCount > 0,
                correlationSampleCount: sequenceCount,
                waveformAvailable: retainsAudio,
                waveformUnavailableReason: retainsAudio
                    ? nil
                    : "Waveforms cannot be reconstructed because raw audio was not retained by the selected privacy policy."
            )
        )
        let configurationPayload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            configurationPayload = try encoder.encode(configuration)
        } catch {
            throw MeasurementStorageError.encodingFailed(
                type: "NewMeasurementConfiguration",
                message: error.localizedDescription
            )
        }
        let session = MeasurementHistorySession(
            id: sessionID,
            createdAt: now,
            updatedAt: now,
            name: "\(reference.fileName) ↔ \(recording.fileName)",
            measurementType: .offlineFile,
            savePolicy: policy,
            configurationPayload: configurationPayload,
            configurationSummary: configurationSummary(configuration),
            appVersion: appVersion,
            algorithmVersion: Self.algorithmVersion,
            runs: [run]
        )
        do {
            try await repository.saveSession(session)
        } catch {
            removeUncommittedCopies(copiedRelativePaths)
            throw error
        }
        return sessionID
    }

    private func storedFile(
        _ file: ImportedAudioFile,
        role: StoredFileRole,
        runID: UUID,
        policy: MeasurementSavePolicy,
        copiedRelativePaths: inout [String]
    ) throws -> StoredAudioFileMetadata {
        let bookmark: Data?
        let relativeAudioPath: String?
        switch policy {
        case .resultsOnly:
            bookmark = nil
            relativeAudioPath = nil
        case .securityScopedBookmarks:
            do {
                bookmark = try file.fileURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                relativeAudioPath = nil
            } catch {
                throw MeasurementStorageError.queryFailed(
                    operation: "create security-scoped bookmark",
                    message: error.localizedDescription
                )
            }
        case .audioCopies:
            bookmark = nil
            relativeAudioPath = try copyAudio(file.fileURL, role: role, runID: runID)
            if let relativeAudioPath { copiedRelativePaths.append(relativeAudioPath) }
        case .doNotSave:
            bookmark = nil
            relativeAudioPath = nil
        }
        return StoredAudioFileMetadata(
            role: role,
            privacyIdentifier: UUID().uuidString,
            fileName: file.fileURL.lastPathComponent,
            container: file.originalFormat.container.rawValue,
            encoding: file.originalFormat.encoding.rawValue,
            format: file.internalFormat,
            frameCount: file.frameCount,
            durationSeconds: file.duration.value,
            peakMagnitude: Double(file.peakMagnitude),
            rootMeanSquare: Double(file.rootMeanSquare),
            clippingSampleCount: file.clippingSampleCount,
            dcOffset: Double(file.dcOffset),
            securityScopedBookmark: bookmark,
            audioCopyRelativePath: relativeAudioPath
        )
    }

    private func copyAudio(_ sourceURL: URL, role: StoredFileRole, runID: UUID) throws -> String {
        guard let audioContainerURL else {
            throw MeasurementStorageError.queryFailed(
                operation: "copy source audio",
                message: "The application support container is unavailable."
            )
        }
        let audioDirectory = audioContainerURL.appendingPathComponent("Audio", isDirectory: true)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension.lowercased()
        let relativePath = "Audio/\(runID.uuidString)-\(role.rawValue).\(fileExtension)"
        let destination = audioContainerURL.appendingPathComponent(relativePath)
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw MeasurementStorageError.queryFailed(
                operation: "copy source audio",
                message: error.localizedDescription
            )
        }
        return relativePath
    }

    private func removeUncommittedCopies(_ relativePaths: [String]) {
        guard let audioContainerURL else { return }
        let root = audioContainerURL.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for relativePath in relativePaths {
            let target = root.appendingPathComponent(relativePath).standardizedFileURL
            guard target.path.hasPrefix(rootPrefix) else { continue }
            try? fileManager.removeItem(at: target)
        }
    }

    private func storedProcessingSteps(
        _ file: ImportedAudioFile,
        role: StoredFileRole
    ) -> [StoredProcessingStep] {
        file.preprocessingLog.map { entry in
            StoredProcessingStep(
                role: role,
                sequence: entry.sequence,
                operationCode: operationCode(entry.operation),
                summary: entry.operation.summary,
                inputFrameCount: entry.inputFrameCount,
                outputFrameCount: entry.outputFrameCount
            )
        }
    }

    private func operationCode(_ operation: PreprocessingOperation) -> String {
        switch operation {
        case .selectedChannel: "selectedChannel"
        case .downmixedToMono: "downmixedToMono"
        case .removedDCOffset: "removedDCOffset"
        case .trimmedLeadingSilence: "trimmedLeadingSilence"
        case .trimmedTrailingSilence: "trimmedTrailingSilence"
        case .highPassFiltered: "highPassFiltered"
        case .resampled: "resampled"
        case .invertedPolarity: "invertedPolarity"
        case .appliedGain: "appliedGain"
        case .peakNormalized: "peakNormalized"
        case .rmsNormalized: "rmsNormalized"
        }
    }

    private func configurationSummary(_ configuration: NewMeasurementConfiguration) -> [String: String] {
        [
            "referenceChannel": String(configuration.referenceChannel),
            "recordingChannel": String(configuration.recordingChannel),
            "downmixToMono": String(configuration.downmixToMono),
            "polarityHandling": configuration.polarityHandling.rawValue,
            "minimumDelayMilliseconds": String(configuration.minimumDelayMilliseconds),
            "maximumDelayMilliseconds": String(configuration.maximumDelayMilliseconds),
            "normalization": configuration.normalization.rawValue,
            "removeDCOffset": String(configuration.removeDCOffset),
            "highPassEnabled": String(configuration.highPassEnabled),
            "highPassCutoffHertz": String(configuration.highPassCutoffHertz),
            "resamplingStrategy": configuration.resamplingStrategy.rawValue,
            "correlationMethod": configuration.correlationMethod.rawValue,
            "minimumOverlapRatio": String(configuration.minimumOverlapRatio),
            "interpolateSubsample": String(configuration.interpolateSubsample)
        ]
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "development"
    }
}

extension MeasurementSavePolicy {
    var userTitle: String {
        switch self {
        case .resultsOnly: "Save results only (recommended)"
        case .securityScopedBookmarks: "Save file access bookmarks"
        case .audioCopies: "Copy audio into AudioLink"
        case .doNotSave: "Do not save this measurement"
        }
    }

    var privacyExplanation: String {
        switch self {
        case .resultsOnly:
            "Stores file names, formats, configuration, results, diagnostics, and correlation cache. No path or audio is retained."
        case .securityScopedBookmarks:
            "Also stores permission bookmarks so the selected source files may be reopened later."
        case .audioCopies:
            "Copies both source files into the AudioLink application container."
        case .doNotSave:
            "Keeps this result only until it is replaced or the app exits."
        }
    }
}
