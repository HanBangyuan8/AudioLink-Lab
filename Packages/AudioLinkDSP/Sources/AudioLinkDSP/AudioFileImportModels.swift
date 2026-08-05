import AudioLinkCore
import Foundation

public enum AudioFileContainer: String, Codable, CaseIterable, Sendable {
    case wav
    case aiff
    case caf
    case m4a
    case unknown
}

public enum AudioFileSampleEncoding: String, Codable, CaseIterable, Sendable {
    case signedIntegerPCM
    case ieeeFloat
    case compressed
    case unknown
}

public struct AudioFileFormatDescription: Codable, Equatable, Sendable {
    public let container: AudioFileContainer
    public let encoding: AudioFileSampleEncoding
    public let sampleRate: SampleRate
    public let channelCount: Int
    public let bitDepth: Int
    public let isInterleaved: Bool
    public let isBigEndian: Bool
    public let formatIdentifier: String

    public init(
        container: AudioFileContainer,
        encoding: AudioFileSampleEncoding,
        sampleRate: SampleRate,
        channelCount: Int,
        bitDepth: Int,
        isInterleaved: Bool,
        isBigEndian: Bool,
        formatIdentifier: String
    ) {
        self.container = container
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.isInterleaved = isInterleaved
        self.isBigEndian = isBigEndian
        self.formatIdentifier = formatIdentifier
    }
}

public struct AudioAnalysisMetrics: Codable, Equatable, Sendable {
    public let peakMagnitude: Float
    public let rootMeanSquare: Float
    public let clippingSampleCount: Int
    public let dcOffset: Float
    public let channelDCOffsets: [Float]

    public init(
        peakMagnitude: Float,
        rootMeanSquare: Float,
        clippingSampleCount: Int,
        dcOffset: Float,
        channelDCOffsets: [Float]
    ) {
        self.peakMagnitude = peakMagnitude
        self.rootMeanSquare = rootMeanSquare
        self.clippingSampleCount = clippingSampleCount
        self.dcOffset = dcOffset
        self.channelDCOffsets = channelDCOffsets
    }
}

public enum AudioImportPhase: String, Codable, CaseIterable, Sendable {
    case opening
    case readingHeader
    case decoding
    case analyzing
    case completed
}

public struct AudioImportProgress: Codable, Equatable, Sendable {
    public let phase: AudioImportPhase
    public let completedFrames: Int64
    public let totalFrames: Int64?

    public init(phase: AudioImportPhase, completedFrames: Int64, totalFrames: Int64?) {
        self.phase = phase
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
    }

    public var fractionCompleted: Double? {
        guard let totalFrames, totalFrames > 0 else { return nil }
        return min(1, max(0, Double(completedFrames) / Double(totalFrames)))
    }
}

public typealias AudioImportProgressHandler = @Sendable (AudioImportProgress) -> Void

public struct AudioPreprocessingProgress: Codable, Equatable, Sendable {
    public let completedOperationCount: Int
    public let totalOperationCount: Int

    public init(completedOperationCount: Int, totalOperationCount: Int) {
        self.completedOperationCount = completedOperationCount
        self.totalOperationCount = totalOperationCount
    }

    public var fractionCompleted: Double {
        guard totalOperationCount > 0 else { return 1 }
        return min(1, max(0, Double(completedOperationCount) / Double(totalOperationCount)))
    }
}

public typealias AudioPreprocessingProgressHandler = @Sendable (AudioPreprocessingProgress) -> Void

public enum PreprocessingOperation: Codable, Equatable, Sendable {
    case selectedChannel(index: Int)
    case downmixedToMono(sourceChannelCount: Int)
    case removedDCOffset(channelOffsets: [Float])
    case trimmedLeadingSilence(frames: Int, threshold: Float)
    case trimmedTrailingSilence(frames: Int, threshold: Float)
    case highPassFiltered(cutoffFrequencyHertz: Double)
    case resampled(
        sourceSampleRate: SampleRate,
        destinationSampleRate: SampleRate,
        inputFrames: Int,
        outputFrames: Int
    )
    case invertedPolarity
    case appliedGain(gain: Float)
    case peakNormalized(target: Float, appliedGain: Float)
    case rmsNormalized(target: Float, appliedGain: Float)
}

public extension PreprocessingOperation {
    var summary: String {
        switch self {
        case let .selectedChannel(index):
            "Selected channel \(index)"
        case let .downmixedToMono(sourceChannelCount):
            "Downmixed \(sourceChannelCount) channels to mono"
        case let .removedDCOffset(offsets):
            "Removed DC offsets \(offsets)"
        case let .trimmedLeadingSilence(frames, threshold):
            "Trimmed \(frames) leading frames at threshold \(threshold)"
        case let .trimmedTrailingSilence(frames, threshold):
            "Trimmed \(frames) trailing frames at threshold \(threshold)"
        case let .highPassFiltered(cutoff):
            "Applied high-pass filter at \(cutoff) Hz"
        case let .resampled(sourceRate, destinationRate, inputFrames, outputFrames):
            "Resampled \(inputFrames) frames at \(sourceRate.hertz) Hz to \(outputFrames) frames at \(destinationRate.hertz) Hz"
        case .invertedPolarity:
            "Inverted polarity"
        case let .appliedGain(gain):
            "Applied linear gain \(gain)"
        case let .peakNormalized(target, gain):
            "Peak normalized to \(target) with gain \(gain)"
        case let .rmsNormalized(target, gain):
            "RMS normalized to \(target) with gain \(gain)"
        }
    }
}

public struct PreprocessingLogEntry: Codable, Equatable, Sendable {
    public let sequence: Int
    public let operation: PreprocessingOperation
    public let inputFrameCount: Int
    public let outputFrameCount: Int

    public init(
        sequence: Int,
        operation: PreprocessingOperation,
        inputFrameCount: Int,
        outputFrameCount: Int
    ) {
        self.sequence = sequence
        self.operation = operation
        self.inputFrameCount = inputFrameCount
        self.outputFrameCount = outputFrameCount
    }
}

public struct ImportedAudioFile: Equatable, Sendable {
    public let fileURL: URL
    public let fileName: String
    public let originalFormat: AudioFileFormatDescription
    public let audio: AudioSampleBuffer
    public let analysis: AudioAnalysisMetrics
    public let metadata: [String: String]
    public let preprocessingLog: [PreprocessingLogEntry]

    public init(
        fileURL: URL,
        fileName: String,
        originalFormat: AudioFileFormatDescription,
        audio: AudioSampleBuffer,
        analysis: AudioAnalysisMetrics,
        metadata: [String: String] = [:],
        preprocessingLog: [PreprocessingLogEntry] = []
    ) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.originalFormat = originalFormat
        self.audio = audio
        self.analysis = analysis
        self.metadata = metadata
        self.preprocessingLog = preprocessingLog
    }

    public var internalFormat: AudioFormatDescriptor { audio.format }
    public var sampleRate: SampleRate { audio.format.sampleRate }
    public var channelCount: Int { audio.channelCount }
    public var frameCount: Int { audio.frameCount }
    public var duration: DurationSeconds { audio.duration }
    public var peakMagnitude: Float { analysis.peakMagnitude }
    public var rootMeanSquare: Float { analysis.rootMeanSquare }
    public var clippingSampleCount: Int { analysis.clippingSampleCount }
    public var dcOffset: Float { analysis.dcOffset }
    public var wasResampled: Bool {
        preprocessingLog.contains { entry in
            if case .resampled = entry.operation { return true }
            return false
        }
    }
    public var preprocessingSummary: [String] {
        preprocessingLog.map(\.operation.summary)
    }
}

public enum AudioImportError: Error, Equatable, Sendable {
    case fileNotFound(URL)
    case accessDenied(path: String)
    case emptyFile(URL)
    case corruptedFile(reason: String)
    case unsupportedContainer(extension: String)
    case unsupportedChannelCount(Int)
    case unsupportedWAVEncoding(formatCode: UInt16, bitDepth: Int)
    case readInterrupted(ErrorContext)
    case decodingFailed(ErrorContext)
    case inputTooLarge(maximumFrames: Int64)
    case cancelled
}

extension AudioImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            "The selected audio file no longer exists."
        case .accessDenied:
            "AudioLink Lab does not have permission to read the selected file."
        case .emptyFile:
            "The selected audio file is empty."
        case .corruptedFile:
            "The audio file is damaged or incomplete."
        case .unsupportedContainer:
            "This audio file container is not supported by the importer."
        case .unsupportedChannelCount:
            "The baseline importer currently supports mono and stereo audio."
        case .unsupportedWAVEncoding:
            "This WAV sample encoding or bit depth is not supported."
        case .readInterrupted:
            "Reading the audio file was interrupted."
        case .decodingFailed:
            "The audio file could not be decoded."
        case .inputTooLarge:
            "The selected audio file is larger than the configured safe import limit."
        case .cancelled:
            "Audio import was cancelled."
        }
    }

    public var debugDescription: String {
        switch self {
        case let .fileNotFound(url):
            "File not found: \(url.lastPathComponent)"
        case let .accessDenied(path):
            "Access denied for file: \(URL(fileURLWithPath: path).lastPathComponent)"
        case let .emptyFile(url):
            "Empty file: \(url.lastPathComponent)"
        case let .corruptedFile(reason):
            reason
        case let .unsupportedContainer(fileExtension):
            "Unsupported extension: \(fileExtension)"
        case let .unsupportedChannelCount(count):
            "Unsupported channel count: \(count)"
        case let .unsupportedWAVEncoding(formatCode, bitDepth):
            "Unsupported WAV format code \(formatCode), bit depth \(bitDepth)"
        case let .readInterrupted(context), let .decodingFailed(context):
            context.diagnosticMessage
        case let .inputTooLarge(maximumFrames):
            "Decoded audio exceeds the \(maximumFrames)-frame safety limit."
        case .cancelled:
            "The importing task observed cancellation."
        }
    }
}

public protocol AudioDecodingService: Sendable {
    func decodeAudioFile(
        at url: URL,
        progress: AudioImportProgressHandler?
    ) async throws -> ImportedAudioFile
}

public struct SilenceTrimmingConfiguration: Codable, Equatable, Sendable {
    public let threshold: Float
    public let minimumSilenceDuration: DurationSeconds

    public init(threshold: Float, minimumSilenceDuration: DurationSeconds = .zero) {
        self.threshold = threshold
        self.minimumSilenceDuration = minimumSilenceDuration
    }
}

public struct HighPassFilterConfiguration: Codable, Equatable, Sendable {
    public let cutoffFrequencyHertz: Double

    public init(cutoffFrequencyHertz: Double) {
        self.cutoffFrequencyHertz = cutoffFrequencyHertz
    }
}

/// Operations run in property order: channel selection, downmix, DC removal,
/// leading/trailing trim, high-pass, resampling, polarity, gain, normalization.
/// A nil/false property never modifies the audio implicitly.
public struct PreprocessingConfiguration: Codable, Equatable, Sendable {
    public let selectedChannel: Int?
    public let downmixToMono: Bool
    public let removeDCOffset: Bool
    public let trimLeadingSilence: SilenceTrimmingConfiguration?
    public let trimTrailingSilence: SilenceTrimmingConfiguration?
    public let highPassFilter: HighPassFilterConfiguration?
    public let targetSampleRate: SampleRate?
    public let invertPolarity: Bool
    public let gain: Float?
    public let peakNormalizationTarget: Float?
    public let rmsNormalizationTarget: Float?

    public init(
        selectedChannel: Int? = nil,
        downmixToMono: Bool = false,
        removeDCOffset: Bool = false,
        trimLeadingSilence: SilenceTrimmingConfiguration? = nil,
        trimTrailingSilence: SilenceTrimmingConfiguration? = nil,
        highPassFilter: HighPassFilterConfiguration? = nil,
        targetSampleRate: SampleRate? = nil,
        invertPolarity: Bool = false,
        gain: Float? = nil,
        peakNormalizationTarget: Float? = nil,
        rmsNormalizationTarget: Float? = nil
    ) {
        self.selectedChannel = selectedChannel
        self.downmixToMono = downmixToMono
        self.removeDCOffset = removeDCOffset
        self.trimLeadingSilence = trimLeadingSilence
        self.trimTrailingSilence = trimTrailingSilence
        self.highPassFilter = highPassFilter
        self.targetSampleRate = targetSampleRate
        self.invertPolarity = invertPolarity
        self.gain = gain
        self.peakNormalizationTarget = peakNormalizationTarget
        self.rmsNormalizationTarget = rmsNormalizationTarget
    }

    public static let none = PreprocessingConfiguration()
}

public enum AudioPreprocessingError: Error, Equatable, Sendable {
    case conflictingChannelOperations
    case conflictingNormalizations
    case invalidChannelSelection(requested: Int, available: Int)
    case invalidSilenceThreshold(Float)
    case invalidHighPassCutoff(value: Double, nyquist: Double)
    case invalidGain(Float)
    case invalidNormalizationTarget(Float)
    case silentAudioCannotBeNormalized
    case operationWouldClip(operation: String, resultingPeak: Float)
    case conversionFailed(ErrorContext)
    case cancelled
}

extension AudioPreprocessingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .conflictingChannelOperations:
            "Select one channel or request a downmix, but not both."
        case .conflictingNormalizations:
            "Peak and RMS normalization cannot be requested together."
        case .invalidChannelSelection:
            "The requested channel does not exist in the imported audio."
        case .invalidSilenceThreshold:
            "Silence threshold must be finite and between zero and one."
        case .invalidHighPassCutoff:
            "High-pass cutoff must be positive and lower than Nyquist."
        case .invalidGain:
            "Gain must be finite and non-negative."
        case .invalidNormalizationTarget:
            "Normalization target must be finite and between zero and one."
        case .silentAudioCannotBeNormalized:
            "Silent audio cannot be normalized."
        case .operationWouldClip:
            "The requested operation would exceed normalized full scale."
        case .conversionFailed:
            "Sample-rate conversion could not be completed."
        case .cancelled:
            "Audio preprocessing was cancelled."
        }
    }
}
