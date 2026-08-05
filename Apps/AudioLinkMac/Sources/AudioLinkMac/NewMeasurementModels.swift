import AudioLinkCore
import AudioLinkDSP
import Foundation

enum NewMeasurementFileRole: String, Codable, CaseIterable, Sendable {
    case reference
    case recording

    var displayName: String {
        switch self {
        case .reference: "Reference"
        case .recording: "Recording"
        }
    }
}

enum NewMeasurementPolarityHandling: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case positiveOnly
    case negativeOnly
    case invertRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic (detect inversion)"
        case .positiveOnly: "Positive peaks only"
        case .negativeOnly: "Negative peaks only"
        case .invertRecording: "Invert recording before analysis"
        }
    }
}

enum NewMeasurementNormalization: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case peak
    case rms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .peak: "Peak to −1 dBFS"
        case .rms: "RMS to −18 dBFS"
        }
    }
}

enum NewMeasurementResamplingStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case recordingToReference
    case referenceToRecording
    case requireMatching

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordingToReference: "Match recording to reference"
        case .referenceToRecording: "Match reference to recording"
        case .requireMatching: "Require matching sample rates"
        }
    }
}

struct NewMeasurementConfiguration: Codable, Equatable, Sendable {
    var referenceChannel = 0
    var recordingChannel = 0
    var downmixToMono = false
    var polarityHandling = NewMeasurementPolarityHandling.automatic
    var minimumDelayMilliseconds = 0.0
    var maximumDelayMilliseconds = 2_000.0
    var normalization = NewMeasurementNormalization.none
    var removeDCOffset = true
    var highPassEnabled = false
    var highPassCutoffHertz = 20.0
    var resamplingStrategy = NewMeasurementResamplingStrategy.recordingToReference
    var correlationMethod = CorrelationMethod.automatic
    var minimumOverlapRatio = 0.5
    var interpolateSubsample = true

    static let userDefault = NewMeasurementConfiguration()

    func validate(reference: ImportedAudioFile?, recording: ImportedAudioFile?) throws {
        guard minimumDelayMilliseconds.isFinite,
              maximumDelayMilliseconds.isFinite,
              minimumDelayMilliseconds <= maximumDelayMilliseconds else {
            throw NewMeasurementWorkflowError.invalidSearchRange(
                minimumMilliseconds: minimumDelayMilliseconds,
                maximumMilliseconds: maximumDelayMilliseconds
            )
        }
        guard minimumOverlapRatio.isFinite, (0...1).contains(minimumOverlapRatio), minimumOverlapRatio > 0 else {
            throw NewMeasurementWorkflowError.invalidAdvancedConfiguration(
                "Minimum overlap must be greater than zero and no greater than one."
            )
        }
        if highPassEnabled {
            guard highPassCutoffHertz.isFinite, highPassCutoffHertz > 0 else {
                throw NewMeasurementWorkflowError.invalidAdvancedConfiguration(
                    "High-pass cutoff must be greater than zero."
                )
            }
        }
        if let reference, !(0..<reference.channelCount).contains(referenceChannel) {
            throw NewMeasurementWorkflowError.invalidChannel(
                role: .reference,
                requested: referenceChannel,
                available: reference.channelCount
            )
        }
        if let recording, !(0..<recording.channelCount).contains(recordingChannel) {
            throw NewMeasurementWorkflowError.invalidChannel(
                role: .recording,
                requested: recordingChannel,
                available: recording.channelCount
            )
        }
    }

    func searchRange(at sampleRate: SampleRate) throws -> SampleLagRange {
        let minimum = minimumDelayMilliseconds / 1_000 * sampleRate.hertz
        let maximum = maximumDelayMilliseconds / 1_000 * sampleRate.hertz
        guard minimum.isFinite,
              maximum.isFinite,
              minimum >= Double(Int64.min),
              minimum <= Double(Int64.max),
              maximum >= Double(Int64.min),
              maximum <= Double(Int64.max) else {
            throw NewMeasurementWorkflowError.invalidSearchRange(
                minimumMilliseconds: minimumDelayMilliseconds,
                maximumMilliseconds: maximumDelayMilliseconds
            )
        }
        return SampleLagRange(
            minimum: Int64(minimum.rounded()),
            maximum: Int64(maximum.rounded())
        )
    }
}

enum NewMeasurementFeatureState: Equatable, Sendable {
    case idle
    case importing(NewMeasurementFileRole)
    case ready
    case analyzing
    case completed
    case failed(NewMeasurementFailure)
    case cancelled

    var isBusy: Bool {
        switch self {
        case .importing, .analyzing: true
        default: false
        }
    }
}

enum NewMeasurementWorkflowError: Error, Equatable, Sendable {
    case invalidSearchRange(minimumMilliseconds: Double, maximumMilliseconds: Double)
    case invalidAdvancedConfiguration(String)
    case invalidChannel(role: NewMeasurementFileRole, requested: Int, available: Int)
    case sampleRateMismatch(reference: SampleRate, recording: SampleRate)
    case signalTooShort(role: NewMeasurementFileRole, frameCount: Int, minimumFrames: Int)
    case noTrustworthyPeak
}

struct NewMeasurementAnalysis: Equatable, Sendable {
    let id: UUID
    let preparedReference: ImportedAudioFile
    let preparedRecording: ImportedAudioFile
    let analysisChannel: Int
    let assessment: QualityAssessedMeasurement
    let presentation: NewMeasurementResultPresentation
}

struct NewMeasurementResultPresentation: Codable, Equatable, Sendable {
    let estimatedDelayMilliseconds: Double?
    let integerSampleDelay: Int64?
    let fractionalSampleDelay: Double?
    let sampleRateHertz: Double
    let confidence: Double
    let qualityLevel: MeasurementQualityLevel
    let peakCorrelation: Double?
    let polarity: String
    let summary: String
    let warnings: [QualityIssuePresentation]
    let recommendations: [String]

    init(assessment: QualityAssessedMeasurement) {
        let delay = assessment.delay
        let qualityContent = MeasurementQualityFormatter().presentation(for: assessment.quality)
        self.estimatedDelayMilliseconds = delay?.fractionalMilliseconds
        self.integerSampleDelay = delay?.sampleOffset.rawValue
        self.fractionalSampleDelay = delay?.fractionalSampleOffset
        self.sampleRateHertz = delay?.sampleRate.hertz
            ?? assessment.quality.delayDiagnostics.selectedDelay?.sampleRate.hertz
            ?? 0
        self.confidence = assessment.quality.confidence.value
        self.qualityLevel = assessment.quality.level
        self.peakCorrelation = assessment.correlation?.normalizedPeak
        if assessment.quality.signal.isPolarityInverted == true {
            self.polarity = "Inverted"
        } else if assessment.quality.signal.isPolarityInverted == false {
            self.polarity = "Normal"
        } else {
            self.polarity = "Unknown"
        }
        self.summary = assessment.quality.summary
        self.warnings = qualityContent.warnings
        self.recommendations = qualityContent.recommendations
    }

    var structuredText: String {
        let delayText = estimatedDelayMilliseconds.map { String(format: "%.6f", $0) } ?? "unavailable"
        let integerText = integerSampleDelay.map(String.init) ?? "unavailable"
        let fractionalText = fractionalSampleDelay.map { String(format: "%.6f", $0) } ?? "unavailable"
        let peakText = peakCorrelation.map { String(format: "%.6f", $0) } ?? "unavailable"
        var lines = [
            "AudioLink Lab Measurement",
            "estimated_delay_ms: \(delayText)",
            "integer_delay_samples: \(integerText)",
            "fractional_delay_samples: \(fractionalText)",
            "sample_rate_hz: \(String(format: "%.0f", sampleRateHertz))",
            "quality: \(qualityLevel.rawValue)",
            "confidence: \(String(format: "%.4f", confidence))",
            "peak_correlation: \(peakText)",
            "polarity: \(polarity.lowercased())",
            "summary: \(summary)"
        ]
        for warning in warnings {
            lines.append("warning[\(warning.code.rawValue)]: \(warning.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

enum NewMeasurementFailureCode: String, Codable, Sendable {
    case unreadableFile
    case unsupportedFormat
    case sampleRateMismatch
    case signalTooShort
    case invalidSearchRange
    case noTrustworthyPeak
    case insufficientMemory
    case cancelled
    case permissionLost
    case invalidPreprocessing
    case analysisFailed
}

struct NewMeasurementFailure: Error, Codable, Equatable, Sendable, Identifiable {
    var id: NewMeasurementFailureCode { code }
    let code: NewMeasurementFailureCode
    let title: String
    let message: String
    let recoverySuggestion: String
    let technicalContext: String?

    static func from(_ error: any Error) -> NewMeasurementFailure {
        if error is CancellationError {
            return cancelled
        }
        if let workflow = error as? NewMeasurementWorkflowError {
            return from(workflow)
        }
        if let importError = error as? AudioImportError {
            return from(importError)
        }
        if let preprocessingError = error as? AudioPreprocessingError {
            if case .cancelled = preprocessingError { return cancelled }
            return NewMeasurementFailure(
                code: .invalidPreprocessing,
                title: "Preprocessing could not be applied",
                message: preprocessingError.errorDescription ?? "The selected preprocessing settings are not valid for this audio.",
                recoverySuggestion: "Review channel, normalization, and high-pass settings, then analyze again.",
                technicalContext: String(describing: preprocessingError)
            )
        }
        if let correlationError = error as? CorrelationAnalysisError {
            switch correlationError {
            case .cancelled:
                return cancelled
            case let .sampleRateMismatch(reference, observed):
                return sampleRateMismatch(reference: reference, recording: observed)
            case .invalidSearchRange, .searchRangeOutsideValidLags, .insufficientOverlap:
                return NewMeasurementFailure(
                    code: .invalidSearchRange,
                    title: "Delay search range is invalid",
                    message: correlationError.errorDescription ?? "The requested delay range cannot be analyzed.",
                    recoverySuggestion: "Use a narrower range that overlaps the recording and reference.",
                    technicalContext: correlationError.debugDescription
                )
            case .insufficientReferenceSignal, .insufficientObservedSignal, .noPeakMatchingPolarity:
                return noTrustworthyPeak(technicalContext: correlationError.debugDescription)
            case .fftLengthOverflow, .fftSetupFailure:
                return NewMeasurementFailure(
                    code: .insufficientMemory,
                    title: "Analysis needs too much memory",
                    message: "The selected files or delay range cannot be analyzed with the available FFT resources.",
                    recoverySuggestion: "Trim the files, reduce the delay range, or choose Direct only for very short files.",
                    technicalContext: correlationError.debugDescription
                )
            default:
                return analysisFailed(technicalContext: correlationError.debugDescription)
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileReadNoSuchFileError].contains(nsError.code) {
            return NewMeasurementFailure(
                code: .permissionLost,
                title: "File access was lost",
                message: "AudioLink Lab can no longer access one of the selected files.",
                recoverySuggestion: "Select the file again to grant access for this app session.",
                technicalContext: "Cocoa error \(nsError.code)"
            )
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOMEM) {
            return NewMeasurementFailure(
                code: .insufficientMemory,
                title: "Not enough memory",
                message: "macOS could not allocate enough memory to complete the analysis.",
                recoverySuggestion: "Use shorter files or reduce the delay search range, then try again.",
                technicalContext: "POSIX ENOMEM"
            )
        }
        return analysisFailed(technicalContext: String(describing: error))
    }

    static let cancelled = NewMeasurementFailure(
        code: .cancelled,
        title: "Operation cancelled",
        message: "The current import or analysis was cancelled.",
        recoverySuggestion: "You can change the files or start the analysis again.",
        technicalContext: nil
    )

    private static func from(_ error: NewMeasurementWorkflowError) -> NewMeasurementFailure {
        switch error {
        case let .invalidSearchRange(minimum, maximum):
            return NewMeasurementFailure(
                code: .invalidSearchRange,
                title: "Delay search range is invalid",
                message: "Minimum delay (\(minimum) ms) must not exceed maximum delay (\(maximum) ms).",
                recoverySuggestion: "Enter a finite minimum and maximum delay with minimum ≤ maximum.",
                technicalContext: String(describing: error)
            )
        case let .invalidAdvancedConfiguration(message):
            return NewMeasurementFailure(
                code: .invalidPreprocessing,
                title: "Advanced setting is invalid",
                message: message,
                recoverySuggestion: "Restore the default advanced settings and try again.",
                technicalContext: String(describing: error)
            )
        case let .invalidChannel(role, requested, available):
            return NewMeasurementFailure(
                code: .invalidPreprocessing,
                title: "Audio channel is unavailable",
                message: "\(role.displayName) channel \(requested + 1) is not present; this file has \(available) channel(s).",
                recoverySuggestion: "Choose an available channel or enable mono downmix.",
                technicalContext: String(describing: error)
            )
        case let .sampleRateMismatch(reference, recording):
            return sampleRateMismatch(reference: reference, recording: recording)
        case let .signalTooShort(role, frameCount, minimumFrames):
            return NewMeasurementFailure(
                code: .signalTooShort,
                title: "Audio is too short",
                message: "The \(role.displayName.lowercased()) contains \(frameCount) frames; at least \(minimumFrames) are required.",
                recoverySuggestion: "Choose a longer, non-empty WAV file.",
                technicalContext: String(describing: error)
            )
        case .noTrustworthyPeak:
            return noTrustworthyPeak(technicalContext: nil)
        }
    }

    private static func from(_ error: AudioImportError) -> NewMeasurementFailure {
        switch error {
        case .cancelled:
            return cancelled
        case .accessDenied:
            return NewMeasurementFailure(
                code: .permissionLost,
                title: "File access was denied",
                message: "AudioLink Lab does not have permission to read the selected audio file.",
                recoverySuggestion: "Select the file again, or copy it to a folder you can access.",
                technicalContext: error.debugDescription
            )
        case .unsupportedContainer, .unsupportedChannelCount, .unsupportedWAVEncoding:
            return NewMeasurementFailure(
                code: .unsupportedFormat,
                title: "Audio format is not supported",
                message: error.errorDescription ?? "The selected file is not a supported WAV format.",
                recoverySuggestion: "Use mono or stereo WAV with 16/24/32-bit PCM or Float32 PCM.",
                technicalContext: error.debugDescription
            )
        case .fileNotFound:
            return NewMeasurementFailure(
                code: .permissionLost,
                title: "Selected file is no longer available",
                message: error.errorDescription ?? "The file was moved, deleted, or its access permission expired.",
                recoverySuggestion: "Select the file again.",
                technicalContext: error.debugDescription
            )
        case .emptyFile, .corruptedFile, .readInterrupted, .decodingFailed, .inputTooLarge:
            return NewMeasurementFailure(
                code: .unreadableFile,
                title: "Audio file could not be read",
                message: error.errorDescription ?? "The selected audio file is empty, damaged, or incomplete.",
                recoverySuggestion: "Verify the WAV in another audio tool or export it again.",
                technicalContext: error.debugDescription
            )
        }
    }

    private static func sampleRateMismatch(reference: SampleRate, recording: SampleRate) -> NewMeasurementFailure {
        NewMeasurementFailure(
            code: .sampleRateMismatch,
            title: "Sample rates do not match",
            message: "Reference is \(reference.hertz.formatted()) Hz and recording is \(recording.hertz.formatted()) Hz.",
            recoverySuggestion: "Choose a resampling strategy or import files with the same sample rate.",
            technicalContext: "reference=\(reference.hertz), recording=\(recording.hertz)"
        )
    }

    private static func noTrustworthyPeak(technicalContext: String?) -> NewMeasurementFailure {
        NewMeasurementFailure(
            code: .noTrustworthyPeak,
            title: "No trustworthy delay peak was found",
            message: "The recording does not contain a sufficiently clear match for the reference signal.",
            recoverySuggestion: "Check routing and gain, reduce noise, widen the delay range, or record again.",
            technicalContext: technicalContext
        )
    }

    private static func analysisFailed(technicalContext: String?) -> NewMeasurementFailure {
        NewMeasurementFailure(
            code: .analysisFailed,
            title: "Analysis could not be completed",
            message: "AudioLink Lab encountered an error while preparing or comparing the files.",
            recoverySuggestion: "Review the selected files and settings, then try again.",
            technicalContext: technicalContext
        )
    }
}
