import Foundation

public enum MeasurementCapability: String, Codable, CaseIterable, Sendable {
    case fileInput
    case realtimeAudio
    case coreAudioDevice
    case audioUnit
    case signalPath
    case spatialCoordinates
    case distributedNetwork
    case headlessExecution
}

public enum MeasurementInputRequirement: String, Codable, CaseIterable, Sendable {
    case audioFile
    case audioDevice
    case pluginComponent
    case signalPathDescription
    case spatialProject
    case distributedPlan
}

public enum MeasurementPermission: String, Codable, CaseIterable, Sendable {
    case microphone
    case localNetwork
    case fileAccess
    case pluginAccess
    case deviceConfiguration
    case recordingStorage
}

public struct MeasurementModuleDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let identifier: String
    public let name: String
    public let version: String
    public let supportedPlatforms: [String]
    public let requiredPermissions: [MeasurementPermission]
    public let requiredHardware: [String]
    public let inputTypes: [MeasurementInputRequirement]
    public let outputTypes: [String]
    public let supportedExportFormats: [String]
    public let configurationSchema: String
    public let supportsCancellation: Bool
    public let supportsHeadlessMode: Bool
    public let supportsDistributedExecution: Bool
    public var id: String { identifier }

    public init(identifier: String, name: String, version: String = "1.0",
                supportedPlatforms: [String] = ["macOS"], requiredPermissions: [MeasurementPermission] = [],
                requiredHardware: [String] = [], inputTypes: [MeasurementInputRequirement] = [],
                outputTypes: [String] = [], supportedExportFormats: [String] = ["json"],
                configurationSchema: String = "1.0", supportsCancellation: Bool = true,
                supportsHeadlessMode: Bool = true, supportsDistributedExecution: Bool = false) {
        self.identifier = identifier; self.name = name; self.version = version
        self.supportedPlatforms = supportedPlatforms; self.requiredPermissions = requiredPermissions
        self.requiredHardware = requiredHardware; self.inputTypes = inputTypes; self.outputTypes = outputTypes
        self.supportedExportFormats = supportedExportFormats; self.configurationSchema = configurationSchema
        self.supportsCancellation = supportsCancellation; self.supportsHeadlessMode = supportsHeadlessMode
        self.supportsDistributedExecution = supportsDistributedExecution
    }
}

public struct MeasurementProvenance: Codable, Equatable, Sendable {
    public let moduleIdentifier: String
    public let moduleVersion: String
    public let algorithmVersion: String
    public let appVersion: String
    public let createdAt: Date

    public init(moduleIdentifier: String, moduleVersion: String, algorithmVersion: String,
                appVersion: String, createdAt: Date = Date()) {
        self.moduleIdentifier = moduleIdentifier; self.moduleVersion = moduleVersion
        self.algorithmVersion = algorithmVersion; self.appVersion = appVersion; self.createdAt = createdAt
    }
}

public struct MeasurementWarning: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let technicalDetails: String?
    public init(code: String, message: String, technicalDetails: String? = nil) {
        self.code = code; self.message = message; self.technicalDetails = technicalDetails
    }
}

public struct MeasurementArtifact: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let relativePath: String
    public let contentType: String
    public let byteCount: Int64?
    public let isSensitive: Bool
    public init(id: UUID = UUID(), relativePath: String, contentType: String,
                byteCount: Int64? = nil, isSensitive: Bool = false) {
        self.id = id; self.relativePath = relativePath; self.contentType = contentType
        self.byteCount = byteCount; self.isSensitive = isSensitive
    }
}

public struct MeasurementResultEnvelope: Codable, Equatable, Sendable {
    public static let schemaVersion = "1.0"
    public let schemaVersion: String
    public let jobID: UUID
    public let provenance: MeasurementProvenance
    public let configuration: JSONValue
    public let environment: JSONValue?
    public let payload: JSONValue
    public let warnings: [MeasurementWarning]
    public let uncertainty: JSONValue?
    public let artifacts: [MeasurementArtifact]
    public let processingLog: [String]

    public init(jobID: UUID, provenance: MeasurementProvenance, configuration: JSONValue,
                environment: JSONValue? = nil, payload: JSONValue,
                warnings: [MeasurementWarning] = [], uncertainty: JSONValue? = nil,
                artifacts: [MeasurementArtifact] = [], processingLog: [String] = []) {
        self.schemaVersion = Self.schemaVersion; self.jobID = jobID; self.provenance = provenance
        self.configuration = configuration; self.environment = environment; self.payload = payload
        self.warnings = warnings; self.uncertainty = uncertainty; self.artifacts = artifacts; self.processingLog = processingLog
    }
}

/// A small JSON value type keeps external schemas independent of Swift type names.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public struct MeasurementExecutionContext: Sendable {
    public let jobID: UUID
    public let configuration: JSONValue
    public let timeout: Duration
    public init(jobID: UUID, configuration: JSONValue, timeout: Duration = .seconds(300)) {
        self.jobID = jobID; self.configuration = configuration; self.timeout = timeout
    }
}

public protocol MeasurementModule: Sendable {
    var descriptor: MeasurementModuleDescriptor { get }
    func execute(context: MeasurementExecutionContext) async throws -> MeasurementResultEnvelope
}

public struct AnyMeasurementModule: MeasurementModule, Sendable {
    public let descriptor: MeasurementModuleDescriptor
    private let operation: @Sendable (MeasurementExecutionContext) async throws -> MeasurementResultEnvelope
    public init(descriptor: MeasurementModuleDescriptor,
                operation: @escaping @Sendable (MeasurementExecutionContext) async throws -> MeasurementResultEnvelope) {
        self.descriptor = descriptor; self.operation = operation
    }
    public func execute(context: MeasurementExecutionContext) async throws -> MeasurementResultEnvelope { try await operation(context) }
}

public enum BuiltInMeasurementModules {
    public static let descriptors: [MeasurementModuleDescriptor] = [
        .init(identifier: "file-delay-analysis", name: "File Delay Analysis", requiredPermissions: [.fileAccess], inputTypes: [.audioFile], outputTypes: ["delay", "quality"]),
        .init(identifier: "realtime-loopback", name: "Realtime Loopback", requiredPermissions: [.microphone, .recordingStorage], requiredHardware: ["input/output device"], inputTypes: [.audioDevice], outputTypes: ["delay", "quality"]),
        .init(identifier: "device-benchmark", name: "Device Benchmark", requiredPermissions: [.deviceConfiguration], requiredHardware: ["Core Audio device"], inputTypes: [.audioDevice], outputTypes: ["benchmark summary"]),
        .init(identifier: "plugin-profiler", name: "Plugin Profiler", requiredPermissions: [.pluginAccess], requiredHardware: ["Audio Unit"], inputTypes: [.pluginComponent], outputTypes: ["plugin profile"]),
        .init(identifier: "signal-path", name: "Signal Path", requiredPermissions: [.fileAccess], inputTypes: [.signalPathDescription], outputTypes: ["path result"]),
        .init(identifier: "clock-drift", name: "Clock Drift", inputTypes: [.audioFile], outputTypes: ["drift"]),
        .init(identifier: "spatial-ir", name: "Spatial IR", requiredPermissions: [.fileAccess], inputTypes: [.spatialProject], outputTypes: ["acoustic metrics"]),
        .init(identifier: "distributed-measurement", name: "Distributed Measurement", requiredPermissions: [.localNetwork], inputTypes: [.distributedPlan], outputTypes: ["distributed result"], supportsDistributedExecution: true)
    ]
}

public enum MeasurementJobState: String, Codable, CaseIterable, Sendable { case queued, preparing, running, exporting, completed, failed, cancelled }

public struct MeasurementJobProgress: Codable, Equatable, Sendable {
    public let fraction: Double?
    public let message: String
    public init(fraction: Double? = nil, message: String) { self.fraction = fraction; self.message = message }
}

public struct MeasurementJob: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let moduleIdentifier: String
    public let createdAt: Date
    public let resourceKeys: [String]
    public var state: MeasurementJobState
    public var progress: MeasurementJobProgress?
    public var errorMessage: String?
    public init(id: UUID = UUID(), moduleIdentifier: String, createdAt: Date = Date(), resourceKeys: [String] = [], state: MeasurementJobState = .queued, progress: MeasurementJobProgress? = nil, errorMessage: String? = nil) {
        self.id = id; self.moduleIdentifier = moduleIdentifier; self.createdAt = createdAt; self.resourceKeys = resourceKeys
        self.state = state; self.progress = progress; self.errorMessage = errorMessage
    }
}

public enum MeasurementJobError: Error, Equatable, Sendable, LocalizedError {
    case unknownJob(UUID)
    case duplicateResource(String)
    case moduleFailure(String)
    case cancelled
    public var errorDescription: String? {
        switch self { case .unknownJob: "The measurement job does not exist."; case .duplicateResource: "A requested measurement resource is already in use."; case .moduleFailure(let message): message; case .cancelled: "The measurement job was cancelled." }
    }
}

/// FIFO executor with a single active resource set. This conservative default
/// prevents two jobs from touching the same device, plugin helper, or network
/// coordinator; the lock policy can be relaxed later without changing modules.
public actor MeasurementJobQueue {
    private struct Pending: Sendable { let job: MeasurementJob; let module: AnyMeasurementModule; let context: MeasurementExecutionContext }
    private var pending: [Pending] = []
    private var jobs: [UUID: MeasurementJob] = [:]
    private var tasks: [UUID: Task<MeasurementResultEnvelope, Error>] = [:]
    private var results: [UUID: MeasurementResultEnvelope] = [:]
    private var activeResources: Set<String> = []
    private var activeJobID: UUID?

    public init() {}

    public func submit(module: AnyMeasurementModule, configuration: JSONValue,
                       timeout: Duration = .seconds(300), resourceKeys: [String] = []) -> UUID {
        let duplicate = Set(resourceKeys).count != resourceKeys.count
        let id = UUID()
        var job = MeasurementJob(id: id, moduleIdentifier: module.descriptor.identifier, resourceKeys: resourceKeys)
        if duplicate { job.state = .failed; job.errorMessage = MeasurementJobError.duplicateResource("duplicate key").localizedDescription }
        jobs[id] = job
        guard !duplicate else { return id }
        pending.append(Pending(job: job, module: module, context: MeasurementExecutionContext(jobID: id, configuration: configuration, timeout: timeout)))
        drain()
        return id
    }

    public func job(_ id: UUID) -> MeasurementJob? { jobs[id] }
    public func result(_ id: UUID) -> MeasurementResultEnvelope? { results[id] }

    public func cancel(_ id: UUID) throws {
        guard var job = jobs[id] else { throw MeasurementJobError.unknownJob(id) }
        if let task = tasks[id] { task.cancel(); return }
        pending.removeAll { $0.job.id == id }
        job.state = .cancelled; job.errorMessage = MeasurementJobError.cancelled.localizedDescription; jobs[id] = job
    }

    private func drain() {
        guard activeJobID == nil, let nextIndex = pending.firstIndex(where: { !activeResources.intersection($0.job.resourceKeys).isEmpty == false }) else { return }
        let next = pending.remove(at: nextIndex)
        activeJobID = next.job.id; activeResources.formUnion(next.job.resourceKeys)
        var job = next.job
        job.state = .preparing
        job.progress = MeasurementJobProgress(fraction: 0, message: "Preparing \(next.module.descriptor.name)")
        jobs[job.id] = job
        let id = job.id
        let task = Task { [module = next.module, context = next.context] in
            try await withThrowingTaskGroup(of: MeasurementResultEnvelope.self) { group in
                group.addTask { try await module.execute(context: context) }
                group.addTask {
                    try await Task.sleep(for: context.timeout)
                    throw MeasurementJobError.moduleFailure("The job exceeded its timeout.")
                }
                guard let value = try await group.next() else { throw MeasurementJobError.moduleFailure("The module returned no result.") }
                group.cancelAll(); return value
            }
        }
        tasks[id] = task
        job.state = .running
        job.progress = MeasurementJobProgress(fraction: 0.1, message: "Running \(next.module.descriptor.name)")
        jobs[id] = job
        Task { [weak self] in
            do { let result = try await task.value; await self?.finish(id: id, result: result, error: nil) }
            catch { await self?.finish(id: id, result: nil, error: error) }
        }
    }

    private func finish(id: UUID, result: MeasurementResultEnvelope?, error: Error?) {
        if var job = jobs[id] {
            if let result { results[id] = result; job.state = .completed; job.progress = MeasurementJobProgress(fraction: 1, message: "Completed") }
            else if error is CancellationError || (error as? MeasurementJobError) == .cancelled { job.state = .cancelled; job.errorMessage = MeasurementJobError.cancelled.localizedDescription }
            else { job.state = .failed; job.errorMessage = error?.localizedDescription ?? "The measurement module failed." }
            jobs[id] = job
        }
        tasks[id] = nil
        activeResources.subtract(jobs[id]?.resourceKeys ?? [])
        activeJobID = nil
        drain()
    }
}
