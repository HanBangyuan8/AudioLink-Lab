import AudioLinkCore
import AudioLinkDSP
import AudioLinkPlatform
import Foundation

public enum AutomationJobState: String, Codable, CaseIterable, Sendable { case queued, preparing, running, exporting, completed, failed, cancelled }

public struct AutomationAuthorization: Codable, Equatable, Sendable {
    public let token: String
    public let allowedDirectories: [URL]
    public let maximumRequestBytes: Int
    public let maximumConcurrentJobs: Int

    public init(token: String = UUID().uuidString, allowedDirectories: [URL] = [], maximumRequestBytes: Int = 1_048_576, maximumConcurrentJobs: Int = 2) {
        self.token = token
        self.allowedDirectories = allowedDirectories.map { $0.standardizedFileURL }
        self.maximumRequestBytes = max(1, maximumRequestBytes)
        self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
    }

    public func isAuthorized(_ suppliedToken: String?) -> Bool { suppliedToken == token }
    public func canRead(_ url: URL) -> Bool {
        // Resolve symlinks before applying the allow-list.  Without this check a
        // permitted directory could contain a link that escapes into an
        // unrelated part of the filesystem.
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return allowedDirectories.contains {
            let root = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return candidate == root || candidate.hasPrefix(root + "/")
        }
    }
}

public struct FileAnalysisConfiguration: Codable, Equatable, Sendable {
    public var channel: Int
    public var method: CorrelationMethod
    public var sampleRate: Double?
    public var searchMinimum: Int64?
    public var searchMaximum: Int64?
    public var normalize: Bool
    public var includeCorrelationSequence: Bool

    public init(channel: Int = 0, method: CorrelationMethod = .automatic, sampleRate: Double? = nil,
                searchMinimum: Int64? = nil, searchMaximum: Int64? = nil, normalize: Bool = true,
                includeCorrelationSequence: Bool = false) {
        self.channel = channel; self.method = method; self.sampleRate = sampleRate
        self.searchMinimum = searchMinimum; self.searchMaximum = searchMaximum; self.normalize = normalize
        self.includeCorrelationSequence = includeCorrelationSequence
    }
}

public struct HeadlessFileAnalysisResult: Codable, Equatable, Sendable {
    public static let schemaVersion = "1.0"
    public let schemaVersion: String
    public let referenceFileName: String
    public let recordingFileName: String
    public let sampleRateHertz: Double
    public let referenceFrames: Int
    public let recordingFrames: Int
    public let integerSampleDelay: Int64
    public let fractionalSampleDelay: Double?
    public let delayMilliseconds: Double
    public let peakCorrelation: Double
    public let peakToSidelobeRatio: Double
    public let confidence: Double
    public let validity: DelayAnalysisValidity
    public let polarity: String
    public let implementation: CorrelationImplementation
    public let warnings: [String]
    public let correlationSequence: CorrelationSequence?

    public init(referenceFileName: String, recordingFileName: String, sampleRateHertz: Double,
                referenceFrames: Int, recordingFrames: Int, integerSampleDelay: Int64,
                fractionalSampleDelay: Double?, delayMilliseconds: Double, peakCorrelation: Double,
                peakToSidelobeRatio: Double, confidence: Double, validity: DelayAnalysisValidity,
                polarity: String, implementation: CorrelationImplementation, warnings: [String] = [],
                correlationSequence: CorrelationSequence? = nil) {
        self.schemaVersion = Self.schemaVersion; self.referenceFileName = referenceFileName; self.recordingFileName = recordingFileName
        self.sampleRateHertz = sampleRateHertz; self.referenceFrames = referenceFrames; self.recordingFrames = recordingFrames
        self.integerSampleDelay = integerSampleDelay; self.fractionalSampleDelay = fractionalSampleDelay; self.delayMilliseconds = delayMilliseconds
        self.peakCorrelation = peakCorrelation; self.peakToSidelobeRatio = peakToSidelobeRatio; self.confidence = confidence
        self.validity = validity; self.polarity = polarity; self.implementation = implementation; self.warnings = warnings; self.correlationSequence = correlationSequence
    }
}

public struct HeadlessFileAnalyzer: Sendable {
    public init() {}

    public func analyze(referenceURL: URL, recordingURL: URL, configuration: FileAnalysisConfiguration = .init()) async throws -> HeadlessFileAnalysisResult {
        let importer = AudioFileImporter()
        async let referenceTask = importer.importFile(at: referenceURL)
        async let recordingTask = importer.importFile(at: recordingURL)
        let reference = try await referenceTask
        let recording = try await recordingTask
        guard reference.sampleRate == recording.sampleRate else {
            throw CorrelationAnalysisError.sampleRateMismatch(reference: reference.sampleRate, observed: recording.sampleRate)
        }
        let referenceSamples = try reference.audio.withUnsafeChannelSamples(channel: configuration.channel) { Array($0) }
        let recordingSamples = try recording.audio.withUnsafeChannelSamples(channel: configuration.channel) { Array($0) }
        let searchRange: SampleLagRange?
        if let minimum = configuration.searchMinimum, let maximum = configuration.searchMaximum { searchRange = SampleLagRange(minimum: minimum, maximum: maximum) }
        else if configuration.searchMinimum != nil || configuration.searchMaximum != nil { throw CorrelationAnalysisError.invalidConfiguration("Both searchMinimum and searchMaximum are required.") }
        else { searchRange = nil }
        let correlationConfiguration = CorrelationConfiguration(method: configuration.method,
            normalization: configuration.normalize ? .overlapEnergy : .none, searchRange: searchRange,
            sequenceOutput: configuration.includeCorrelationSequence ? .searchedRange : .none, channel: configuration.channel)
        let correlation = try await CorrelationEngine().correlate(reference: referenceSamples, observed: recordingSamples, configuration: correlationConfiguration)
        let sampleRate = reference.sampleRate.hertz
        let fractional = correlation.primaryPeak?.fractionalLag
        let polarity = (correlation.primaryPeak?.value ?? 0) < 0 ? "inverted" : "positive"
        var warnings = correlation.diagnostics?.notes ?? []
        if correlation.diagnostics?.validity != .valid { warnings.append("Correlation validity is \(correlation.diagnostics?.validity.rawValue ?? "unknown").") }
        return HeadlessFileAnalysisResult(referenceFileName: reference.fileName, recordingFileName: recording.fileName,
            sampleRateHertz: sampleRate, referenceFrames: reference.frameCount, recordingFrames: recording.frameCount,
            integerSampleDelay: correlation.peakOffset.rawValue, fractionalSampleDelay: fractional,
            delayMilliseconds: (fractional ?? Double(correlation.peakOffset.rawValue)) / sampleRate * 1_000,
            peakCorrelation: correlation.primaryPeak?.value ?? correlation.normalizedPeak,
            peakToSidelobeRatio: correlation.peakToSidelobeRatio, confidence: correlation.confidence,
            validity: correlation.diagnostics?.validity ?? .lowConfidence, polarity: polarity,
            implementation: correlation.diagnostics?.implementation ?? .fft, warnings: warnings,
            correlationSequence: correlation.sequence)
    }
}

public struct AutomationRequest: Codable, Equatable, Sendable {
    public let operation: String
    public let referenceFile: String?
    public let recordingFile: String?
    public let configuration: FileAnalysisConfiguration?
    public init(operation: String, referenceFile: String? = nil, recordingFile: String? = nil, configuration: FileAnalysisConfiguration? = nil) {
        self.operation = operation; self.referenceFile = referenceFile; self.recordingFile = recordingFile; self.configuration = configuration
    }
}

public enum AutomationFailurePolicy: String, Codable, CaseIterable, Sendable { case stop, continueOnError }

public struct AutomationPlanTask: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let operation: String
    public let referenceFile: String?
    public let recordingFile: String?
    public let configuration: FileAnalysisConfiguration?
    public init(id: UUID = UUID(), operation: String, referenceFile: String? = nil,
                recordingFile: String? = nil, configuration: FileAnalysisConfiguration? = nil) {
        self.id = id; self.operation = operation; self.referenceFile = referenceFile
        self.recordingFile = recordingFile; self.configuration = configuration
    }
    private enum CodingKeys: String, CodingKey { case id, operation, referenceFile, recordingFile, configuration }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.operation = try container.decode(String.self, forKey: .operation)
        self.referenceFile = try container.decodeIfPresent(String.self, forKey: .referenceFile)
        self.recordingFile = try container.decodeIfPresent(String.self, forKey: .recordingFile)
        self.configuration = try container.decodeIfPresent(FileAnalysisConfiguration.self, forKey: .configuration)
    }
}

public struct AutomationPlan: Codable, Equatable, Sendable {
    public static let schemaVersion = "1.0"
    public let schemaVersion: String
    public let metadata: [String: String]
    public let deviceSelectors: [String: String]
    public let measurementMode: String
    public let signalConfiguration: JSONValue?
    public let preprocessing: JSONValue?
    public let repetitions: Int
    public let exportFormats: [String]
    public let tasks: [AutomationPlanTask]
    public let failurePolicy: AutomationFailurePolicy
    public let privacy: [String: String]
    public let timeoutSeconds: Double

    public init(schemaVersion: String = Self.schemaVersion, metadata: [String: String] = [:],
                deviceSelectors: [String: String] = [:], measurementMode: String = "file-analysis",
                signalConfiguration: JSONValue? = nil, preprocessing: JSONValue? = nil,
                repetitions: Int = 1, exportFormats: [String] = ["json"], tasks: [AutomationPlanTask],
                failurePolicy: AutomationFailurePolicy = .stop, privacy: [String: String] = [:],
                timeoutSeconds: Double = 300) {
        self.schemaVersion = schemaVersion; self.metadata = metadata; self.deviceSelectors = deviceSelectors
        self.measurementMode = measurementMode; self.signalConfiguration = signalConfiguration; self.preprocessing = preprocessing
        self.repetitions = repetitions; self.exportFormats = exportFormats; self.tasks = tasks; self.failurePolicy = failurePolicy
        self.privacy = privacy; self.timeoutSeconds = timeoutSeconds
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, metadata, deviceSelectors, measurementMode, signalConfiguration, preprocessing, repetitions, exportFormats, tasks, failurePolicy, privacy, timeoutSeconds }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? Self.schemaVersion
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        self.deviceSelectors = try container.decodeIfPresent([String: String].self, forKey: .deviceSelectors) ?? [:]
        self.measurementMode = try container.decodeIfPresent(String.self, forKey: .measurementMode) ?? "file-analysis"
        self.signalConfiguration = try container.decodeIfPresent(JSONValue.self, forKey: .signalConfiguration)
        self.preprocessing = try container.decodeIfPresent(JSONValue.self, forKey: .preprocessing)
        self.repetitions = try container.decodeIfPresent(Int.self, forKey: .repetitions) ?? 1
        self.exportFormats = try container.decodeIfPresent([String].self, forKey: .exportFormats) ?? ["json"]
        self.tasks = try container.decode([AutomationPlanTask].self, forKey: .tasks)
        self.failurePolicy = try container.decodeIfPresent(AutomationFailurePolicy.self, forKey: .failurePolicy) ?? .stop
        self.privacy = try container.decodeIfPresent([String: String].self, forKey: .privacy) ?? [:]
        self.timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 300
    }
}

public struct AutomationJobRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let operation: String
    public let createdAt: Date
    public var state: AutomationJobState
    public var progress: Double?
    public var error: String?
    public var result: HeadlessFileAnalysisResult?
    public init(id: UUID = UUID(), operation: String, createdAt: Date = Date(), state: AutomationJobState = .queued,
                progress: Double? = nil, error: String? = nil, result: HeadlessFileAnalysisResult? = nil) {
        self.id = id; self.operation = operation; self.createdAt = createdAt; self.state = state
        self.progress = progress; self.error = error; self.result = result
    }
}

public enum AutomationError: Error, Equatable, Sendable, LocalizedError {
    case unauthorized
    case requestTooLarge
    case invalidRequest(String)
    case pathNotAllowed(String)
    case unknownJob(UUID)
    case tooManyJobs
    case unsupportedOperation(String)
    case serverNotRunning
    public var errorDescription: String? {
        switch self { case .unauthorized: "Invalid automation token."; case .requestTooLarge: "The automation request is too large."; case .invalidRequest(let message): message; case .pathNotAllowed: "The requested path is outside the explicitly allowed directories."; case .unknownJob: "The automation job does not exist."; case .tooManyJobs: "The automation service has reached its concurrent job limit."; case .unsupportedOperation: "The requested automation operation is not available."; case .serverNotRunning: "The local automation service is not running." }
    }
}

public actor AutomationJobStore {
    private var jobs: [UUID: AutomationJobRecord] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let maximumHistory = 100
    private let authorization: AutomationAuthorization
    private let analyzer: HeadlessFileAnalyzer

    public init(authorization: AutomationAuthorization, analyzer: HeadlessFileAnalyzer = .init()) {
        self.authorization = authorization; self.analyzer = analyzer
    }

    public func submit(request: AutomationRequest) throws -> UUID {
        guard request.operation == "file-analysis" else { throw AutomationError.unsupportedOperation(request.operation) }
        guard let reference = request.referenceFile, let recording = request.recordingFile else { throw AutomationError.invalidRequest("referenceFile and recordingFile are required.") }
        let referenceURL = URL(fileURLWithPath: reference).standardizedFileURL
        let recordingURL = URL(fileURLWithPath: recording).standardizedFileURL
        guard authorization.canRead(referenceURL), authorization.canRead(recordingURL) else { throw AutomationError.pathNotAllowed("Only configured allowed directories may be read.") }
        let active = tasks.values.count
        guard active < authorization.maximumConcurrentJobs else { throw AutomationError.tooManyJobs }
        let id = UUID()
        jobs[id] = AutomationJobRecord(id: id, operation: request.operation)
        let configuration = request.configuration ?? .init()
        let task = Task { [weak self, analyzer] in
            await self?.update(id: id, state: .preparing, progress: 0.1, error: nil, result: nil)
            do {
                try Task.checkCancellation()
                await self?.update(id: id, state: .running, progress: 0.25, error: nil, result: nil)
                let result = try await analyzer.analyze(referenceURL: referenceURL, recordingURL: recordingURL, configuration: configuration)
                await self?.update(id: id, state: .completed, progress: 1, error: nil, result: result)
            } catch is CancellationError {
                await self?.update(id: id, state: .cancelled, progress: nil, error: "Cancelled", result: nil)
            } catch {
                await self?.update(id: id, state: .failed, progress: nil, error: error.localizedDescription, result: nil)
            }
            await self?.removeTask(id)
        }
        tasks[id] = task
        return id
    }

    public func job(_ id: UUID) throws -> AutomationJobRecord { guard let job = jobs[id] else { throw AutomationError.unknownJob(id) }; return job }
    public func cancel(_ id: UUID) throws { guard let task = tasks[id] else { throw AutomationError.unknownJob(id) }; task.cancel() }
    private func update(id: UUID, state: AutomationJobState, progress: Double?, error: String?, result: HeadlessFileAnalysisResult?) {
        guard var job = jobs[id] else { return }
        job.state = state; job.progress = progress; job.error = error; job.result = result; jobs[id] = job
        trimHistoryIfNeeded()
    }

    private func removeTask(_ id: UUID) {
        tasks[id] = nil
        trimHistoryIfNeeded()
    }

    private func trimHistoryIfNeeded() {
        guard jobs.count > maximumHistory else { return }
        let removable = jobs.values
            .filter { !tasks.keys.contains($0.id) && [.completed, .failed, .cancelled].contains($0.state) }
            .sorted { $0.createdAt < $1.createdAt }
        let countToRemove = jobs.count - maximumHistory
        for job in removable.prefix(countToRemove) { jobs[job.id] = nil }
    }
}
