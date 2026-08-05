import AudioLinkCore
import Foundation

/// The version of the public report interchange format. It is deliberately
/// independent from the SQLite schema and can be decoded by future releases.
public enum ReportSchemaVersion: String, Codable, CaseIterable, Sendable {
    case v1 = "1.0"
}

public enum ReportExportFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case json
    case csv
    case html
    case pdf
    case png

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
}

public struct ReportPrivacyOptions: Codable, Equatable, Sendable {
    /// Detailed identifiers are off by default. A report never includes source
    /// absolute paths or security-scoped bookmarks, even when this is enabled.
    public var includeDetailedDiagnosticIdentifiers: Bool

    public init(includeDetailedDiagnosticIdentifiers: Bool = false) {
        self.includeDetailedDiagnosticIdentifiers = includeDetailedDiagnosticIdentifiers
    }
}

public struct ReportChapterSelection: Codable, Equatable, Sendable {
    public var executiveSummary: Bool
    public var measurementSetup: Bool
    public var deviceInformation: Bool
    public var signalConfiguration: Bool
    public var audioFormat: Bool
    public var delayResult: Bool
    public var statisticalSummary: Bool
    public var qualityAndConfidence: Bool
    public var warnings: Bool
    public var calibration: Bool
    public var drift: Bool
    public var charts: Bool
    public var processingLog: Bool
    public var versions: Bool
    public var reproducibility: Bool
    public var notes: Bool

    public init(includeAll: Bool = true) {
        executiveSummary = includeAll
        measurementSetup = includeAll
        deviceInformation = includeAll
        signalConfiguration = includeAll
        audioFormat = includeAll
        delayResult = includeAll
        statisticalSummary = includeAll
        qualityAndConfidence = includeAll
        warnings = includeAll
        calibration = includeAll
        drift = includeAll
        charts = includeAll
        processingLog = includeAll
        versions = includeAll
        reproducibility = includeAll
        notes = includeAll
    }
}

public struct ReportPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let xUnit: String
    public let yUnit: String

    public init(x: Double, y: Double, xUnit: String, yUnit: String) {
        self.x = x
        self.y = y
        self.xUnit = xUnit
        self.yUnit = yUnit
    }
}

public struct ReportChartMarker: Codable, Equatable, Sendable {
    public let label: String
    public let x: Double
    public let y: Double?
    public let colorToken: String

    public init(label: String, x: Double, y: Double? = nil, colorToken: String = "accent") {
        self.label = label
        self.x = x
        self.y = y
        self.colorToken = colorToken
    }
}

public struct ReportChart: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: String
    public let points: [ReportPoint]
    public let markers: [ReportChartMarker]
    public let xLabel: String
    public let yLabel: String

    public init(
        id: String,
        title: String,
        kind: String,
        points: [ReportPoint],
        markers: [ReportChartMarker] = [],
        xLabel: String,
        yLabel: String
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.points = points
        self.markers = markers
        self.xLabel = xLabel
        self.yLabel = yLabel
    }
}

public struct ReportAudioFile: Codable, Equatable, Sendable {
    public let role: String
    public let fileName: String
    public let container: String
    public let encoding: String
    public let sampleRateHertz: Double
    public let channelCount: Int
    public let bitDepth: Int
    public let interleaved: Bool
    public let frameCount: Int
    public let durationSeconds: Double
    public let peak: Double
    public let rms: Double
    public let clippingSampleCount: Int
    public let dcOffset: Double
    public let anonymousIdentifier: String?

    public init(
        role: String,
        fileName: String,
        container: String,
        encoding: String,
        sampleRateHertz: Double,
        channelCount: Int,
        bitDepth: Int,
        interleaved: Bool,
        frameCount: Int,
        durationSeconds: Double,
        peak: Double,
        rms: Double,
        clippingSampleCount: Int,
        dcOffset: Double,
        anonymousIdentifier: String? = nil
    ) {
        self.role = role
        self.fileName = fileName
        self.container = container
        self.encoding = encoding
        self.sampleRateHertz = sampleRateHertz
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.interleaved = interleaved
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
        self.peak = peak
        self.rms = rms
        self.clippingSampleCount = clippingSampleCount
        self.dcOffset = dcOffset
        self.anonymousIdentifier = anonymousIdentifier
    }
}

public struct ReportDevice: Codable, Equatable, Sendable {
    public let role: String
    public let name: String
    public let manufacturer: String?
    public let transport: String
    public let supportsInput: Bool
    public let supportsOutput: Bool
    public let diagnosticIdentifier: String?

    public init(
        role: String,
        name: String,
        manufacturer: String?,
        transport: String,
        supportsInput: Bool,
        supportsOutput: Bool,
        diagnosticIdentifier: String? = nil
    ) {
        self.role = role
        self.name = name
        self.manufacturer = manufacturer
        self.transport = transport
        self.supportsInput = supportsInput
        self.supportsOutput = supportsOutput
        self.diagnosticIdentifier = diagnosticIdentifier
    }
}

public struct ReportDelay: Codable, Equatable, Sendable {
    public let integerSamples: Int64?
    public let fractionalSamples: Double?
    public let milliseconds: Double?
    public let sampleRateHertz: Double
    public let peakCorrelation: Double?
    public let peakToSidelobeRatio: Double?
    public let confidence: Double?
    public let polarity: String?
    public let calibratedMilliseconds: Double?
    public let calibrationOffsetSamples: Int64?

    public init(
        integerSamples: Int64?,
        fractionalSamples: Double?,
        milliseconds: Double?,
        sampleRateHertz: Double,
        peakCorrelation: Double?,
        peakToSidelobeRatio: Double?,
        confidence: Double?,
        polarity: String?,
        calibratedMilliseconds: Double? = nil,
        calibrationOffsetSamples: Int64? = nil
    ) {
        self.integerSamples = integerSamples
        self.fractionalSamples = fractionalSamples
        self.milliseconds = milliseconds
        self.sampleRateHertz = sampleRateHertz
        self.peakCorrelation = peakCorrelation
        self.peakToSidelobeRatio = peakToSidelobeRatio
        self.confidence = confidence
        self.polarity = polarity
        self.calibratedMilliseconds = calibratedMilliseconds
        self.calibrationOffsetSamples = calibrationOffsetSamples
    }
}

public struct ReportQuality: Codable, Equatable, Sendable {
    public let level: String
    public let confidence: Double
    public let summary: String
    public let metrics: [String: Double]
    public let issues: [ReportWarning]
    public let candidatePeakSamples: [Int64]
    public let shouldRemeasure: Bool

    public init(
        level: String,
        confidence: Double,
        summary: String,
        metrics: [String: Double],
        issues: [ReportWarning],
        candidatePeakSamples: [Int64] = [],
        shouldRemeasure: Bool
    ) {
        self.level = level
        self.confidence = confidence
        self.summary = summary
        self.metrics = metrics
        self.issues = issues
        self.candidatePeakSamples = candidatePeakSamples
        self.shouldRemeasure = shouldRemeasure
    }
}

public struct ReportWarning: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let severity: String
    public let title: String
    public let detail: String
    public let recommendation: String

    public init(id: String, severity: String, title: String, detail: String, recommendation: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
    }
}

public struct ReportStatistics: Codable, Equatable, Sendable {
    public let outcomeCount: Int
    public let successCount: Int
    public let failureCount: Int
    public let populationCount: Int
    public let includesMarkedOutliers: Bool
    public let minimumMilliseconds: Double?
    public let maximumMilliseconds: Double?
    public let meanMilliseconds: Double?
    public let medianMilliseconds: Double?
    public let varianceMillisecondsSquared: Double?
    public let jitterStandardDeviationMilliseconds: Double?
    public let p50Milliseconds: Double?
    public let p90Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let p99Milliseconds: Double?
    public let peakToPeakJitterMilliseconds: Double?
    public let medianAbsoluteDeviationMilliseconds: Double?
    public let interquartileRangeMilliseconds: Double?
    public let confidenceIntervalLowMilliseconds: Double?
    public let confidenceIntervalHighMilliseconds: Double?
    public let outlierMethod: String?
    public let outlierThreshold: Double?
    public let qualityDistribution: [String: Int]

    public init(
        outcomeCount: Int,
        successCount: Int,
        failureCount: Int,
        populationCount: Int,
        includesMarkedOutliers: Bool,
        minimumMilliseconds: Double?,
        maximumMilliseconds: Double?,
        meanMilliseconds: Double?,
        medianMilliseconds: Double?,
        varianceMillisecondsSquared: Double?,
        jitterStandardDeviationMilliseconds: Double?,
        p50Milliseconds: Double?,
        p90Milliseconds: Double?,
        p95Milliseconds: Double?,
        p99Milliseconds: Double?,
        peakToPeakJitterMilliseconds: Double?,
        medianAbsoluteDeviationMilliseconds: Double?,
        interquartileRangeMilliseconds: Double?,
        confidenceIntervalLowMilliseconds: Double?,
        confidenceIntervalHighMilliseconds: Double?,
        outlierMethod: String?,
        outlierThreshold: Double?,
        qualityDistribution: [String: Int]
    ) {
        self.outcomeCount = outcomeCount
        self.successCount = successCount
        self.failureCount = failureCount
        self.populationCount = populationCount
        self.includesMarkedOutliers = includesMarkedOutliers
        self.minimumMilliseconds = minimumMilliseconds
        self.maximumMilliseconds = maximumMilliseconds
        self.meanMilliseconds = meanMilliseconds
        self.medianMilliseconds = medianMilliseconds
        self.varianceMillisecondsSquared = varianceMillisecondsSquared
        self.jitterStandardDeviationMilliseconds = jitterStandardDeviationMilliseconds
        self.p50Milliseconds = p50Milliseconds
        self.p90Milliseconds = p90Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.p99Milliseconds = p99Milliseconds
        self.peakToPeakJitterMilliseconds = peakToPeakJitterMilliseconds
        self.medianAbsoluteDeviationMilliseconds = medianAbsoluteDeviationMilliseconds
        self.interquartileRangeMilliseconds = interquartileRangeMilliseconds
        self.confidenceIntervalLowMilliseconds = confidenceIntervalLowMilliseconds
        self.confidenceIntervalHighMilliseconds = confidenceIntervalHighMilliseconds
        self.outlierMethod = outlierMethod
        self.outlierThreshold = outlierThreshold
        self.qualityDistribution = qualityDistribution
    }
}

public struct ReportCalibration: Codable, Equatable, Sendable {
    public let profileName: String
    public let method: String
    public let knownDelaySamples: Int64
    public let confidence: Double
    public let applied: Bool
    public let notes: String?

    public init(profileName: String, method: String, knownDelaySamples: Int64, confidence: Double, applied: Bool, notes: String? = nil) {
        self.profileName = profileName
        self.method = method
        self.knownDelaySamples = knownDelaySamples
        self.confidence = confidence
        self.applied = applied
        self.notes = notes
    }
}

public struct ReportDriftObservation: Codable, Equatable, Sendable {
    public let eventIndex: Int
    public let expectedSample: Double
    public let observedSample: Double
    public let errorSamples: Double
    public let timeSeconds: Double
    public let quality: Double?

    public init(eventIndex: Int, expectedSample: Double, observedSample: Double, errorSamples: Double, timeSeconds: Double, quality: Double? = nil) {
        self.eventIndex = eventIndex
        self.expectedSample = expectedSample
        self.observedSample = observedSample
        self.errorSamples = errorSamples
        self.timeSeconds = timeSeconds
        self.quality = quality
    }
}

public struct ReportDrift: Codable, Equatable, Sendable {
    public let relativePartsPerMillion: Double?
    public let constantOffsetSamples: Double?
    public let fitResidualRms: Double?
    public let confidence: Double?
    public let nonLinearWarning: Bool
    public let observations: [ReportDriftObservation]

    public init(relativePartsPerMillion: Double?, constantOffsetSamples: Double?, fitResidualRMS: Double?, confidence: Double?, nonLinearWarning: Bool, observations: [ReportDriftObservation]) {
        self.relativePartsPerMillion = relativePartsPerMillion
        self.constantOffsetSamples = constantOffsetSamples
        self.fitResidualRms = fitResidualRMS
        self.confidence = confidence
        self.nonLinearWarning = nonLinearWarning
        self.observations = observations
    }

    public var fitResidualRMS: Double? { fitResidualRms }
}

public struct ReportProcessingStep: Codable, Equatable, Sendable {
    public let role: String
    public let sequence: Int
    public let operation: String
    public let summary: String
    public let inputFrames: Int
    public let outputFrames: Int

    public init(role: String, sequence: Int, operation: String, summary: String, inputFrames: Int, outputFrames: Int) {
        self.role = role
        self.sequence = sequence
        self.operation = operation
        self.summary = summary
        self.inputFrames = inputFrames
        self.outputFrames = outputFrames
    }
}

public struct ReportRun: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionId: UUID
    public let createdAt: Date
    public let completedAt: Date?
    public let reference: ReportAudioFile
    public let recording: ReportAudioFile
    public let delay: ReportDelay
    public let quality: ReportQuality
    public let statistics: ReportStatistics?
    public let calibration: ReportCalibration?
    public let drift: ReportDrift?
    public let warnings: [ReportWarning]
    public let processingLog: [ReportProcessingStep]
    public let chartCache: [String: String]
    public let notes: String

    public init(id: UUID, sessionID: UUID, createdAt: Date, completedAt: Date?, reference: ReportAudioFile, recording: ReportAudioFile, delay: ReportDelay, quality: ReportQuality, statistics: ReportStatistics? = nil, calibration: ReportCalibration? = nil, drift: ReportDrift? = nil, warnings: [ReportWarning] = [], processingLog: [ReportProcessingStep] = [], chartCache: [String: String] = [:], notes: String = "") {
        self.id = id
        self.sessionId = sessionID
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.reference = reference
        self.recording = recording
        self.delay = delay
        self.quality = quality
        self.statistics = statistics
        self.calibration = calibration
        self.drift = drift
        self.warnings = warnings
        self.processingLog = processingLog
        self.chartCache = chartCache
        self.notes = notes
    }

    public var sessionID: UUID { sessionId }
}

/// Additive, privacy-filtered sections for v1.1 labs. Dictionaries keep the
/// public report stable without exposing internal Core Audio or plugin objects.
public struct ReportLabSection: Codable, Equatable, Sendable {
    public let kind: String
    public let summary: [String: String]
    public let rows: [[String: String]]
    public init(kind: String, summary: [String: String] = [:], rows: [[String: String]] = []) { self.kind = kind; self.summary = summary; self.rows = rows }
}

public struct ReportDocument: Codable, Equatable, Sendable {
    public let schemaVersion: ReportSchemaVersion
    public let reportId: UUID
    public let title: String
    public let generatedAt: Date
    public let sessionId: UUID?
    public let measurementType: String
    public let executiveSummary: String
    public let measurementSetup: [String: String]
    public let devices: [ReportDevice]
    public let signalConfiguration: [String: String]
    public let audioFormat: [String: String]
    public let runs: [ReportRun]
    public let statistics: ReportStatistics?
    public let quality: ReportQuality?
    public let warnings: [ReportWarning]
    public let calibration: ReportCalibration?
    public let drift: ReportDrift?
    public let charts: [ReportChart]
    public let processingLog: [ReportProcessingStep]
    public let appVersion: String
    public let algorithmVersion: String
    public let reproducibility: [String: String]
    public let notes: String?
    public let privacy: ReportPrivacyOptions
    public let deviceProfiler: ReportLabSection?
    public let interfaceBenchmark: ReportLabSection?
    public let pluginProfiler: ReportLabSection?
    public let signalPath: ReportLabSection?
    public let adaptivePlanner: ReportLabSection?
    public let spatialMapper: ReportLabSection?
    public let distributedMeasurement: ReportLabSection?

    public init(schemaVersion: ReportSchemaVersion = .v1, reportID: UUID = UUID(), title: String, generatedAt: Date = Date(), sessionID: UUID?, measurementType: String, executiveSummary: String, measurementSetup: [String: String], devices: [ReportDevice], signalConfiguration: [String: String], audioFormat: [String: String], runs: [ReportRun], statistics: ReportStatistics?, quality: ReportQuality?, warnings: [ReportWarning], calibration: ReportCalibration?, drift: ReportDrift?, charts: [ReportChart], processingLog: [ReportProcessingStep], appVersion: String, algorithmVersion: String, reproducibility: [String: String], notes: String?, privacy: ReportPrivacyOptions, deviceProfiler: ReportLabSection? = nil, interfaceBenchmark: ReportLabSection? = nil, pluginProfiler: ReportLabSection? = nil, signalPath: ReportLabSection? = nil, adaptivePlanner: ReportLabSection? = nil, spatialMapper: ReportLabSection? = nil, distributedMeasurement: ReportLabSection? = nil) {
        self.schemaVersion = schemaVersion
        self.reportId = reportID
        self.title = title
        self.generatedAt = generatedAt
        self.sessionId = sessionID
        self.measurementType = measurementType
        self.executiveSummary = executiveSummary
        self.measurementSetup = measurementSetup
        self.devices = devices
        self.signalConfiguration = signalConfiguration
        self.audioFormat = audioFormat
        self.runs = runs
        self.statistics = statistics
        self.quality = quality
        self.warnings = warnings
        self.calibration = calibration
        self.drift = drift
        self.charts = charts
        self.processingLog = processingLog
        self.appVersion = appVersion
        self.algorithmVersion = algorithmVersion
        self.reproducibility = reproducibility
        self.notes = notes
        self.privacy = privacy
        self.deviceProfiler = deviceProfiler
        self.interfaceBenchmark = interfaceBenchmark
        self.pluginProfiler = pluginProfiler
        self.signalPath = signalPath
        self.adaptivePlanner = adaptivePlanner
        self.spatialMapper = spatialMapper
        self.distributedMeasurement = distributedMeasurement
    }

    /// Compatibility spelling for Swift callers; the wire key is `report_id`.
    public var reportID: UUID { reportId }
    public var sessionID: UUID? { sessionId }
}

public enum ReportExportError: Error, Equatable, LocalizedError, Sendable {
    case noRuns
    case mixedSessions
    case unsupportedFormat(String)
    case invalidDestination
    case writeFailed(String)
    case renderingFailed(String)
    case cancelled
    case chartUnavailable

    public var errorDescription: String? {
        switch self {
        case .noRuns: "The report contains no completed measurement runs."
        case .mixedSessions: "Select runs from one session at a time so the report setup and statistics stay coherent."
        case let .unsupportedFormat(format): "The report format is not supported: \(format)."
        case .invalidDestination: "Choose a writable destination for the report."
        case let .writeFailed(message): "The report could not be written: \(message)"
        case let .renderingFailed(message): "The report could not be rendered: \(message)"
        case .cancelled: "Report export was cancelled."
        case .chartUnavailable: "No chart data is available for PNG export."
        }
    }
}
