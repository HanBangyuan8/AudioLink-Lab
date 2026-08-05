import AudioLinkCore
import Foundation

public struct AudioUnitComponentIdentity: Codable, Equatable, Hashable, Sendable {
    public let type: UInt32
    public let subtype: UInt32
    public let manufacturer: UInt32
    public let version: String
    public init(type: UInt32, subtype: UInt32, manufacturer: UInt32, version: String) { self.type = type; self.subtype = subtype; self.manufacturer = manufacturer; self.version = version }
}

public struct AudioUnitDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let identity: AudioUnitComponentIdentity
    public let name: String
    public let manufacturer: String?
    public let location: String?
    public let validationStatus: PluginCompatibilityStatus
    public let supportsOfflineRendering: Bool?
    public let supportsInPlaceProcessing: Bool?
    public let inputChannels: Int?
    public let outputChannels: Int?
    public let reportedLatencyFrames: Int?
    public let reportedTailSeconds: Double?
    public let hasCustomUI: Bool?
    public init(id: UUID = UUID(), identity: AudioUnitComponentIdentity, name: String, manufacturer: String? = nil, location: String? = nil, validationStatus: PluginCompatibilityStatus = .unknown, supportsOfflineRendering: Bool? = nil, supportsInPlaceProcessing: Bool? = nil, inputChannels: Int? = nil, outputChannels: Int? = nil, reportedLatencyFrames: Int? = nil, reportedTailSeconds: Double? = nil, hasCustomUI: Bool? = nil) { self.id = id; self.identity = identity; self.name = name; self.manufacturer = manufacturer; self.location = location; self.validationStatus = validationStatus; self.supportsOfflineRendering = supportsOfflineRendering; self.supportsInPlaceProcessing = supportsInPlaceProcessing; self.inputChannels = inputChannels; self.outputChannels = outputChannels; self.reportedLatencyFrames = reportedLatencyFrames; self.reportedTailSeconds = reportedTailSeconds; self.hasCustomUI = hasCustomUI }
}

public enum PluginCompatibilityStatus: String, Codable, Sendable { case unknown, validated, failed, timedOut, crashed, unsupported }
public struct PluginScanResult: Codable, Equatable, Sendable { public let descriptor: AudioUnitDescriptor; public let scannedAt: Date; public let diagnostics: [String]; public init(descriptor: AudioUnitDescriptor, scannedAt: Date = Date(), diagnostics: [String] = []) { self.descriptor = descriptor; self.scannedAt = scannedAt; self.diagnostics = diagnostics } }
public struct PluginFailureRecord: Codable, Equatable, Identifiable, Sendable { public let id: UUID; public let plugin: AudioUnitComponentIdentity; public let status: PluginCompatibilityStatus; public let message: String; public let occurredAt: Date; public init(id: UUID = UUID(), plugin: AudioUnitComponentIdentity, status: PluginCompatibilityStatus, message: String, occurredAt: Date = Date()) { self.id = id; self.plugin = plugin; self.status = status; self.message = message; self.occurredAt = occurredAt } }

public struct PluginTestConfiguration: Codable, Equatable, Sendable {
    public let sampleRate: SampleRate
    public let blockSize: Int
    public let durationSeconds: Double
    public let inputAmplitude: Double
    public let presetName: String?
    public let parameterValues: [String: Double]
    public init(sampleRate: SampleRate, blockSize: Int = 128, durationSeconds: Double = 1, inputAmplitude: Double = 0.25, presetName: String? = nil, parameterValues: [String: Double] = [:]) { self.sampleRate = sampleRate; self.blockSize = max(1, blockSize); self.durationSeconds = max(0, durationSeconds); self.inputAmplitude = min(1, max(0, inputAmplitude)); self.presetName = presetName; self.parameterValues = parameterValues }
}

public struct PluginLatencyResult: Codable, Equatable, Sendable { public let reportedFrames: Int?; public let measuredFrames: Double?; public let differenceFrames: Double?; public init(reportedFrames: Int?, measuredFrames: Double?) { self.reportedFrames = reportedFrames; self.measuredFrames = measuredFrames; self.differenceFrames = reportedFrames.flatMap { reported in measuredFrames.map { measured in measured - Double(reported) } } } }
public struct PluginFrequencyResponse: Codable, Equatable, Sendable { public let frequenciesHertz: [Double]; public let magnitudeDB: [Double]; public init(frequenciesHertz: [Double], magnitudeDB: [Double]) { self.frequenciesHertz = frequenciesHertz; self.magnitudeDB = magnitudeDB } }
public struct PluginPhaseResponse: Codable, Equatable, Sendable { public let frequenciesHertz: [Double]; public let phaseRadians: [Double]; public let groupDelaySeconds: [Double]; public init(frequenciesHertz: [Double], phaseRadians: [Double], groupDelaySeconds: [Double]) { self.frequenciesHertz = frequenciesHertz; self.phaseRadians = phaseRadians; self.groupDelaySeconds = groupDelaySeconds } }
public struct PluginDistortionResult: Codable, Equatable, Sendable { public let thdRatio: Double; public let harmonics: [Int: Double]; public init(thdRatio: Double, harmonics: [Int: Double]) { self.thdRatio = thdRatio; self.harmonics = harmonics } }
public struct PluginNoiseResult: Codable, Equatable, Sendable { public let rms: Double; public let hasNonZeroIdleOutput: Bool; public init(rms: Double, hasNonZeroIdleOutput: Bool) { self.rms = rms; self.hasNonZeroIdleOutput = hasNonZeroIdleOutput } }
public struct PluginTailResult: Codable, Equatable, Sendable { public let measuredSeconds: Double?; public let reportedSeconds: Double?; public init(measuredSeconds: Double?, reportedSeconds: Double?) { self.measuredSeconds = measuredSeconds; self.reportedSeconds = reportedSeconds } }
public struct PluginCPUMetrics: Codable, Equatable, Sendable { public let renderedSeconds: Double; public let wallSeconds: Double; public let deadlineMisses: Int; public init(renderedSeconds: Double, wallSeconds: Double, deadlineMisses: Int = 0) { self.renderedSeconds = renderedSeconds; self.wallSeconds = wallSeconds; self.deadlineMisses = deadlineMisses } }
public struct PluginProfileResult: Codable, Equatable, Sendable { public let plugin: AudioUnitDescriptor; public let configuration: PluginTestConfiguration; public let latency: PluginLatencyResult; public let frequencyResponse: PluginFrequencyResponse?; public let phaseResponse: PluginPhaseResponse?; public let distortion: PluginDistortionResult?; public let noise: PluginNoiseResult?; public let tail: PluginTailResult?; public let cpu: PluginCPUMetrics?; public let diagnostics: [String]; public init(plugin: AudioUnitDescriptor, configuration: PluginTestConfiguration, latency: PluginLatencyResult, frequencyResponse: PluginFrequencyResponse? = nil, phaseResponse: PluginPhaseResponse? = nil, distortion: PluginDistortionResult? = nil, noise: PluginNoiseResult? = nil, tail: PluginTailResult? = nil, cpu: PluginCPUMetrics? = nil, diagnostics: [String] = []) { self.plugin = plugin; self.configuration = configuration; self.latency = latency; self.frequencyResponse = frequencyResponse; self.phaseResponse = phaseResponse; self.distortion = distortion; self.noise = noise; self.tail = tail; self.cpu = cpu; self.diagnostics = diagnostics } }

public enum PluginHelperStatus: String, Codable, Sendable { case completed, crashed, timedOut, cancelled, invalidOutput }
public struct AudioUnitHelperRequest: Codable, Equatable, Sendable { public let requestID: UUID; public let plugin: AudioUnitComponentIdentity; public let configuration: PluginTestConfiguration; public init(requestID: UUID = UUID(), plugin: AudioUnitComponentIdentity, configuration: PluginTestConfiguration) { self.requestID = requestID; self.plugin = plugin; self.configuration = configuration } }
public struct AudioUnitHelperResponse: Codable, Equatable, Sendable { public let requestID: UUID; public let status: PluginHelperStatus; public let output: [Float]; public let diagnostics: [String]; public init(requestID: UUID, status: PluginHelperStatus, output: [Float] = [], diagnostics: [String] = []) { self.requestID = requestID; self.status = status; self.output = output; self.diagnostics = diagnostics } }

public protocol AudioUnitPluginRunner: Sendable {
    func render(_ input: [Float], request: AudioUnitHelperRequest) async throws -> AudioUnitHelperResponse
}

public enum AudioUnitProfilerError: Error, Equatable, Sendable { case timeout; case crashed(String); case invalidOutput(String); case unsupported(String); case cancelled }
extension AudioUnitProfilerError: LocalizedError { public var errorDescription: String? { switch self { case .timeout: "The isolated Audio Unit helper timed out."; case let .crashed(message): "The Audio Unit helper stopped unexpectedly: \(message)"; case let .invalidOutput(message): "The Audio Unit returned invalid output: \(message)"; case let .unsupported(message): message; case .cancelled: "Audio Unit profiling was cancelled." } } }
