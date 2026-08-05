import AudioLinkCore
import AudioLinkDSP
import Foundation

protocol NewMeasurementServicing: Sendable {
    func importAudio(at url: URL) async throws -> ImportedAudioFile

    func analyze(
        reference: ImportedAudioFile,
        recording: ImportedAudioFile,
        configuration: NewMeasurementConfiguration
    ) async throws -> NewMeasurementAnalysis
}

struct LiveNewMeasurementService: NewMeasurementServicing, Sendable {
    private static let minimumFrameCount = 16

    private let importer: AudioFileImporter
    private let preprocessor: AudioPreprocessor
    private let qualityAnalyzer: MeasurementQualityAnalyzer

    init(
        importer: AudioFileImporter = .init(),
        preprocessor: AudioPreprocessor = .init(),
        qualityAnalyzer: MeasurementQualityAnalyzer = .init()
    ) {
        self.importer = importer
        self.preprocessor = preprocessor
        self.qualityAnalyzer = qualityAnalyzer
    }

    func importAudio(at url: URL) async throws -> ImportedAudioFile {
        try await importer.importFile(at: url)
    }

    func analyze(
        reference: ImportedAudioFile,
        recording: ImportedAudioFile,
        configuration: NewMeasurementConfiguration
    ) async throws -> NewMeasurementAnalysis {
        try Task.checkCancellation()
        try configuration.validate(reference: reference, recording: recording)

        if configuration.resamplingStrategy == .requireMatching,
           reference.sampleRate != recording.sampleRate {
            throw NewMeasurementWorkflowError.sampleRateMismatch(
                reference: reference.sampleRate,
                recording: recording.sampleRate
            )
        }

        let preservesAllChannels = !configuration.downmixToMono
            && reference.channelCount == recording.channelCount
            && configuration.referenceChannel == configuration.recordingChannel
        let sampleRateTargets = targetSampleRates(
            reference: reference.sampleRate,
            recording: recording.sampleRate,
            strategy: configuration.resamplingStrategy
        )
        let referenceConfiguration = preprocessingConfiguration(
            role: .reference,
            selectedChannel: preservesAllChannels ? nil : configuration.referenceChannel,
            downmix: configuration.downmixToMono,
            targetSampleRate: sampleRateTargets.reference,
            configuration: configuration
        )
        let recordingConfiguration = preprocessingConfiguration(
            role: .recording,
            selectedChannel: preservesAllChannels ? nil : configuration.recordingChannel,
            downmix: configuration.downmixToMono,
            targetSampleRate: sampleRateTargets.recording,
            configuration: configuration
        )

        async let preparedReferenceTask = preprocessor.process(
            reference,
            configuration: referenceConfiguration
        )
        async let preparedRecordingTask = preprocessor.process(
            recording,
            configuration: recordingConfiguration
        )
        let (preparedReference, preparedRecording) = try await (
            preparedReferenceTask,
            preparedRecordingTask
        )
        try Task.checkCancellation()

        try validateLength(preparedReference, role: .reference)
        try validateLength(preparedRecording, role: .recording)
        guard preparedReference.sampleRate == preparedRecording.sampleRate else {
            throw NewMeasurementWorkflowError.sampleRateMismatch(
                reference: preparedReference.sampleRate,
                recording: preparedRecording.sampleRate
            )
        }
        let analysisChannel = preservesAllChannels ? configuration.referenceChannel : 0
        let correlationConfiguration = CorrelationConfiguration(
            method: configuration.correlationMethod,
            normalization: .overlapEnergy,
            searchRange: try configuration.searchRange(at: preparedReference.sampleRate),
            peakSelection: peakSelection(for: configuration.polarityHandling),
            sequenceOutput: .none,
            minimumOverlapRatio: configuration.minimumOverlapRatio,
            interpolateSubsample: configuration.interpolateSubsample,
            channel: analysisChannel
        )
        let assessment = try await qualityAnalyzer.analyze(
            reference: preparedReference,
            observed: preparedRecording,
            correlationConfiguration: correlationConfiguration
        )
        try Task.checkCancellation()
        return NewMeasurementAnalysis(
            id: UUID(),
            preparedReference: preparedReference,
            preparedRecording: preparedRecording,
            analysisChannel: analysisChannel,
            assessment: assessment,
            presentation: NewMeasurementResultPresentation(assessment: assessment)
        )
    }

    private func preprocessingConfiguration(
        role: NewMeasurementFileRole,
        selectedChannel: Int?,
        downmix: Bool,
        targetSampleRate: SampleRate?,
        configuration: NewMeasurementConfiguration
    ) -> PreprocessingConfiguration {
        let normalizationTargets = normalizationTargets(for: configuration.normalization)
        return PreprocessingConfiguration(
            selectedChannel: selectedChannel,
            downmixToMono: downmix,
            removeDCOffset: configuration.removeDCOffset,
            highPassFilter: configuration.highPassEnabled
                ? HighPassFilterConfiguration(cutoffFrequencyHertz: configuration.highPassCutoffHertz)
                : nil,
            targetSampleRate: targetSampleRate,
            invertPolarity: role == .recording && configuration.polarityHandling == .invertRecording,
            peakNormalizationTarget: normalizationTargets.peak,
            rmsNormalizationTarget: normalizationTargets.rms
        )
    }

    private func targetSampleRates(
        reference: SampleRate,
        recording: SampleRate,
        strategy: NewMeasurementResamplingStrategy
    ) -> (reference: SampleRate?, recording: SampleRate?) {
        switch strategy {
        case .recordingToReference:
            return (nil, reference)
        case .referenceToRecording:
            return (recording, nil)
        case .requireMatching:
            return (nil, nil)
        }
    }

    private func normalizationTargets(
        for normalization: NewMeasurementNormalization
    ) -> (peak: Float?, rms: Float?) {
        switch normalization {
        case .none:
            return (nil, nil)
        case .peak:
            return (Float(pow(10, -1.0 / 20.0)), nil)
        case .rms:
            return (nil, Float(pow(10, -18.0 / 20.0)))
        }
    }

    private func peakSelection(
        for handling: NewMeasurementPolarityHandling
    ) -> CorrelationPeakSelection {
        switch handling {
        case .automatic, .invertRecording: .absolute
        case .positiveOnly: .positive
        case .negativeOnly: .negative
        }
    }

    private func validateLength(
        _ file: ImportedAudioFile,
        role: NewMeasurementFileRole
    ) throws {
        guard file.frameCount >= Self.minimumFrameCount else {
            throw NewMeasurementWorkflowError.signalTooShort(
                role: role,
                frameCount: file.frameCount,
                minimumFrames: Self.minimumFrameCount
            )
        }
    }
}
