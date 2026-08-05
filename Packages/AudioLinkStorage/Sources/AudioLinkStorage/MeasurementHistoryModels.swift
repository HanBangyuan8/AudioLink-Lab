import AudioLinkCore
import Foundation

public enum MeasurementSavePolicy: String, Codable, CaseIterable, Sendable {
    /// Store results and non-sensitive metadata only. This is the default.
    case resultsOnly
    /// Store security-scoped bookmarks for the source files when explicitly selected.
    case securityScopedBookmarks
    /// Copy source audio into the app container and store only relative paths.
    case audioCopies
    /// Do not write a history record.
    case doNotSave
}

public enum StoredMeasurementType: String, Codable, CaseIterable, Sendable {
    case offlineFile
    case liveAudio
    case networkLink
}

public enum StoredFileRole: String, Codable, CaseIterable, Sendable {
    case reference
    case recording
}

public struct StoredAudioFileMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let role: StoredFileRole
    public let privacyIdentifier: String
    public let fileName: String
    public let container: String
    public let encoding: String
    public let format: AudioFormatDescriptor
    public let frameCount: Int
    public let durationSeconds: Double
    public let peakMagnitude: Double
    public let rootMeanSquare: Double
    public let clippingSampleCount: Int
    public let dcOffset: Double
    public let securityScopedBookmark: Data?
    /// Path relative to the AudioLink application container, never an absolute path.
    public let audioCopyRelativePath: String?

    public init(
        id: UUID = UUID(),
        role: StoredFileRole,
        privacyIdentifier: String,
        fileName: String,
        container: String,
        encoding: String,
        format: AudioFormatDescriptor,
        frameCount: Int,
        durationSeconds: Double,
        peakMagnitude: Double,
        rootMeanSquare: Double,
        clippingSampleCount: Int,
        dcOffset: Double,
        securityScopedBookmark: Data? = nil,
        audioCopyRelativePath: String? = nil
    ) {
        self.id = id
        self.role = role
        self.privacyIdentifier = privacyIdentifier
        self.fileName = fileName
        self.container = container
        self.encoding = encoding
        self.format = format
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
        self.peakMagnitude = peakMagnitude
        self.rootMeanSquare = rootMeanSquare
        self.clippingSampleCount = clippingSampleCount
        self.dcOffset = dcOffset
        self.securityScopedBookmark = securityScopedBookmark
        self.audioCopyRelativePath = audioCopyRelativePath
    }
}

public struct StoredProcessingStep: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let role: StoredFileRole
    public let sequence: Int
    public let operationCode: String
    public let summary: String
    public let inputFrameCount: Int
    public let outputFrameCount: Int

    public init(
        id: UUID = UUID(),
        role: StoredFileRole,
        sequence: Int,
        operationCode: String,
        summary: String,
        inputFrameCount: Int,
        outputFrameCount: Int
    ) {
        self.id = id
        self.role = role
        self.sequence = sequence
        self.operationCode = operationCode
        self.summary = summary
        self.inputFrameCount = inputFrameCount
        self.outputFrameCount = outputFrameCount
    }
}

public struct StoredChartCacheMetadata: Codable, Equatable, Sendable {
    public let cacheFormatVersion: Int
    public let correlationSequenceAvailable: Bool
    public let correlationSampleCount: Int
    public let waveformAvailable: Bool
    public let waveformUnavailableReason: String?

    public init(
        cacheFormatVersion: Int = 1,
        correlationSequenceAvailable: Bool,
        correlationSampleCount: Int,
        waveformAvailable: Bool,
        waveformUnavailableReason: String? = nil
    ) {
        self.cacheFormatVersion = cacheFormatVersion
        self.correlationSequenceAvailable = correlationSequenceAvailable
        self.correlationSampleCount = correlationSampleCount
        self.waveformAvailable = waveformAvailable
        self.waveformUnavailableReason = waveformUnavailableReason
    }
}

public struct MeasurementHistoryRun: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let createdAt: Date
    public let completedAt: Date?
    public let referenceFile: StoredAudioFileMetadata
    public let recordingFile: StoredAudioFileMetadata
    public let delayEstimate: DelayEstimate?
    public let calibration: CalibratedDelayResult?
    public let correlation: CorrelationResult?
    public let quality: MeasurementQuality
    public let statistics: MeasurementStatistics?
    public let processingSteps: [StoredProcessingStep]
    public let chartCache: StoredChartCacheMetadata
    public let notes: String

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        createdAt: Date,
        completedAt: Date? = nil,
        referenceFile: StoredAudioFileMetadata,
        recordingFile: StoredAudioFileMetadata,
        delayEstimate: DelayEstimate?,
        calibration: CalibratedDelayResult? = nil,
        correlation: CorrelationResult?,
        quality: MeasurementQuality,
        statistics: MeasurementStatistics? = nil,
        processingSteps: [StoredProcessingStep] = [],
        chartCache: StoredChartCacheMetadata,
        notes: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.referenceFile = referenceFile
        self.recordingFile = recordingFile
        self.delayEstimate = delayEstimate
        self.calibration = calibration
        self.correlation = correlation
        self.quality = quality
        self.statistics = statistics
        self.processingSteps = processingSteps.sorted { lhs, rhs in
            lhs.role.rawValue == rhs.role.rawValue
                ? lhs.sequence < rhs.sequence
                : lhs.role.rawValue < rhs.role.rawValue
        }
        self.chartCache = chartCache
        self.notes = notes
    }
}

public struct MeasurementHistorySession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let name: String
    public let notes: String
    public let measurementType: StoredMeasurementType
    public let savePolicy: MeasurementSavePolicy
    /// Encoded feature configuration. The repository treats it as an opaque,
    /// versioned payload so storage does not depend on application UI types.
    public let configurationPayload: Data
    public let configurationSummary: [String: String]
    public let statistics: MeasurementStatistics?
    /// Aggregate statistics for repeated real-time runs. Nil for legacy and
    /// single-run sessions. Raw runs remain authoritative.
    public let repeatedStatistics: RepeatedMeasurementStatistics?
    public let inputDevice: DeviceDescriptor?
    public let outputDevice: DeviceDescriptor?
    public let appVersion: String
    public let algorithmVersion: String
    public let runs: [MeasurementHistoryRun]

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        updatedAt: Date,
        name: String,
        notes: String = "",
        measurementType: StoredMeasurementType,
        savePolicy: MeasurementSavePolicy = .resultsOnly,
        configurationPayload: Data,
        configurationSummary: [String: String],
        statistics: MeasurementStatistics? = nil,
        repeatedStatistics: RepeatedMeasurementStatistics? = nil,
        inputDevice: DeviceDescriptor? = nil,
        outputDevice: DeviceDescriptor? = nil,
        appVersion: String,
        algorithmVersion: String,
        runs: [MeasurementHistoryRun]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.name = name
        self.notes = notes
        self.measurementType = measurementType
        self.savePolicy = savePolicy
        self.configurationPayload = configurationPayload
        self.configurationSummary = configurationSummary
        self.statistics = statistics
        self.repeatedStatistics = repeatedStatistics
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
        self.appVersion = appVersion
        self.algorithmVersion = algorithmVersion
        self.runs = runs
    }
}

public struct MeasurementHistoryQuery: Codable, Equatable, Sendable {
    public var searchText: String
    public var qualityLevels: [MeasurementQualityLevel]
    public var deviceSearchText: String
    public var measurementTypes: [StoredMeasurementType]
    public var pageSize: Int
    public var offset: Int

    public init(
        searchText: String = "",
        qualityLevels: [MeasurementQualityLevel] = [],
        deviceSearchText: String = "",
        measurementTypes: [StoredMeasurementType] = [],
        pageSize: Int = 50,
        offset: Int = 0
    ) {
        self.searchText = searchText
        self.qualityLevels = qualityLevels
        self.deviceSearchText = deviceSearchText
        self.measurementTypes = measurementTypes
        self.pageSize = min(500, max(1, pageSize))
        self.offset = max(0, offset)
    }
}

public struct MeasurementHistoryRunSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let sessionName: String
    public let createdAt: Date
    public let measurementType: StoredMeasurementType
    public let referenceFileName: String
    public let recordingFileName: String
    public let delayMilliseconds: Double?
    public let sampleRateHertz: Double
    public let qualityLevel: MeasurementQualityLevel
    public let confidence: Double
    public let inputDeviceName: String?
    public let outputDeviceName: String?
    public let notes: String

    public init(
        id: UUID,
        sessionID: UUID,
        sessionName: String,
        createdAt: Date,
        measurementType: StoredMeasurementType,
        referenceFileName: String,
        recordingFileName: String,
        delayMilliseconds: Double?,
        sampleRateHertz: Double,
        qualityLevel: MeasurementQualityLevel,
        confidence: Double,
        inputDeviceName: String?,
        outputDeviceName: String?,
        notes: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.createdAt = createdAt
        self.measurementType = measurementType
        self.referenceFileName = referenceFileName
        self.recordingFileName = recordingFileName
        self.delayMilliseconds = delayMilliseconds
        self.sampleRateHertz = sampleRateHertz
        self.qualityLevel = qualityLevel
        self.confidence = confidence
        self.inputDeviceName = inputDeviceName
        self.outputDeviceName = outputDeviceName
        self.notes = notes
    }
}

public struct MeasurementHistoryPage: Codable, Equatable, Sendable {
    public let runs: [MeasurementHistoryRunSummary]
    public let totalCount: Int
    public let offset: Int
    public let pageSize: Int

    public init(runs: [MeasurementHistoryRunSummary], totalCount: Int, offset: Int, pageSize: Int) {
        self.runs = runs
        self.totalCount = totalCount
        self.offset = offset
        self.pageSize = pageSize
    }

    public var hasMore: Bool { offset + runs.count < totalCount }
}

public struct MeasurementRunComparisonEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let summary: MeasurementHistoryRunSummary
    public let delayDifferenceMilliseconds: Double?
    public let confidenceDifference: Double
    public let qualityLevelDifference: String
    public let configurationDifferences: [String]
    public let sampleRateDifferenceHertz: Double
    public let preprocessingDifferences: [String]
    public let deviceDifference: Bool

    public init(
        id: UUID,
        summary: MeasurementHistoryRunSummary,
        delayDifferenceMilliseconds: Double?,
        confidenceDifference: Double,
        qualityLevelDifference: String,
        configurationDifferences: [String],
        sampleRateDifferenceHertz: Double,
        preprocessingDifferences: [String],
        deviceDifference: Bool
    ) {
        self.id = id
        self.summary = summary
        self.delayDifferenceMilliseconds = delayDifferenceMilliseconds
        self.confidenceDifference = confidenceDifference
        self.qualityLevelDifference = qualityLevelDifference
        self.configurationDifferences = configurationDifferences
        self.sampleRateDifferenceHertz = sampleRateDifferenceHertz
        self.preprocessingDifferences = preprocessingDifferences
        self.deviceDifference = deviceDifference
    }
}

public struct MeasurementRunComparison: Codable, Equatable, Sendable {
    public let baselineRunID: UUID
    public let entries: [MeasurementRunComparisonEntry]

    public init(baselineRunID: UUID, entries: [MeasurementRunComparisonEntry]) {
        self.baselineRunID = baselineRunID
        self.entries = entries
    }
}

public struct MeasurementRepositoryInfo: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let databaseSizeBytes: Int64
    public let sessionCount: Int
    public let runCount: Int

    public init(schemaVersion: Int, databaseSizeBytes: Int64, sessionCount: Int, runCount: Int) {
        self.schemaVersion = schemaVersion
        self.databaseSizeBytes = databaseSizeBytes
        self.sessionCount = sessionCount
        self.runCount = runCount
    }
}
