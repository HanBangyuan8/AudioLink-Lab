import AudioLinkCore
import AudioLinkDSP
import Foundation

public enum MeasurementObjective: String, Codable, CaseIterable, Sendable {
    case quick, balanced, highPrecision, noisyEnvironment, longDelayPath, pluginAnalysis, clockDrift, custom
}

public struct MeasurementEnvironment: Codable, Equatable, Sendable {
    public var sampleRate: SampleRate
    public var inputRMS: Double?
    public var noiseFloorRMS: Double?
    public var clippingRatio: Double
    public var roughDelaySamples: Int64?
    public var currentSearchRange: ClosedRange<Int64>?
    public var hasAmbiguousPeaks: Bool
    public var hasLongTail: Bool
    public var possibleResampling: Bool
    public var narrowBand: Bool
    public var polarityInverted: Bool
    public var driftPPM: Double?

    public init(sampleRate: SampleRate, inputRMS: Double? = nil, noiseFloorRMS: Double? = nil,
                clippingRatio: Double = 0, roughDelaySamples: Int64? = nil,
                currentSearchRange: ClosedRange<Int64>? = nil, hasAmbiguousPeaks: Bool = false,
                hasLongTail: Bool = false, possibleResampling: Bool = false, narrowBand: Bool = false,
                polarityInverted: Bool = false, driftPPM: Double? = nil) {
        self.sampleRate = sampleRate; self.inputRMS = inputRMS; self.noiseFloorRMS = noiseFloorRMS
        self.clippingRatio = clippingRatio; self.roughDelaySamples = roughDelaySamples
        self.currentSearchRange = currentSearchRange; self.hasAmbiguousPeaks = hasAmbiguousPeaks
        self.hasLongTail = hasLongTail; self.possibleResampling = possibleResampling
        self.narrowBand = narrowBand; self.polarityInverted = polarityInverted; self.driftPPM = driftPPM
    }

    public var signalToNoiseRatio: Double? {
        guard let inputRMS, let noiseFloorRMS, inputRMS > 0, noiseFloorRMS > 0 else { return nil }
        return 20 * log10(inputRMS / noiseFloorRMS)
    }
}

public struct ProbeMeasurement: Codable, Equatable, Sendable {
    public var duration: DurationSeconds
    public var inputRMS: Double
    public var noiseFloorRMS: Double
    public var clippingRatio: Double
    public var roughDelaySamples: Int64?
    public var hasAmbiguousPeaks: Bool
    public var hasLongTail: Bool
    public var possibleResampling: Bool
    public var availableFrequencyRangeHertz: ClosedRange<Double>?

    public init(duration: DurationSeconds, inputRMS: Double, noiseFloorRMS: Double, clippingRatio: Double = 0,
                roughDelaySamples: Int64? = nil, hasAmbiguousPeaks: Bool = false, hasLongTail: Bool = false,
                possibleResampling: Bool = false, availableFrequencyRangeHertz: ClosedRange<Double>? = nil) {
        self.duration = duration; self.inputRMS = inputRMS; self.noiseFloorRMS = noiseFloorRMS
        self.clippingRatio = clippingRatio; self.roughDelaySamples = roughDelaySamples
        self.hasAmbiguousPeaks = hasAmbiguousPeaks; self.hasLongTail = hasLongTail
        self.possibleResampling = possibleResampling; self.availableFrequencyRangeHertz = availableFrequencyRangeHertz
    }

    public func applying(to environment: MeasurementEnvironment) -> MeasurementEnvironment {
        var value = environment
        value.inputRMS = inputRMS; value.noiseFloorRMS = noiseFloorRMS; value.clippingRatio = clippingRatio
        value.roughDelaySamples = roughDelaySamples; value.hasAmbiguousPeaks = hasAmbiguousPeaks
        value.hasLongTail = hasLongTail; value.possibleResampling = possibleResampling
        return value
    }
}

public struct AdaptiveMeasurementLimits: Codable, Equatable, Sendable {
    public var maximumAmplitude: Float
    public var maximumDuration: DurationSeconds
    public var maximumPreRoll: DurationSeconds
    public var maximumPostRoll: DurationSeconds
    public var maximumRetries: Int
    public var allowAutomaticAmplitude: Bool
    public var allowAutomaticRetry: Bool
    public init(maximumAmplitude: Float = 0.8, maximumDuration: DurationSeconds = (try? DurationSeconds(30)) ?? .oneTenthSecond,
                maximumPreRoll: DurationSeconds = (try? DurationSeconds(1)) ?? .oneTenthSecond,
                maximumPostRoll: DurationSeconds = (try? DurationSeconds(2)) ?? .oneTenthSecond,
                maximumRetries: Int = 2, allowAutomaticAmplitude: Bool = true, allowAutomaticRetry: Bool = true) {
        self.maximumAmplitude = maximumAmplitude; self.maximumDuration = maximumDuration
        self.maximumPreRoll = maximumPreRoll; self.maximumPostRoll = maximumPostRoll
        self.maximumRetries = max(0, maximumRetries); self.allowAutomaticAmplitude = allowAutomaticAmplitude
        self.allowAutomaticRetry = allowAutomaticRetry
    }
}

public enum AdaptiveParameter: String, Codable, CaseIterable, Sendable {
    case signalKind, duration, frequencyRange, amplitude, preRoll, postRoll, repetitionCount
    case markerSpacing, searchRange, normalization, highPass, polarity, correlationMode, retryPolicy
}

public struct AdaptiveParameterLock: Codable, Equatable, Sendable {
    public let parameter: AdaptiveParameter
    public let value: String
    public init(parameter: AdaptiveParameter, value: String) { self.parameter = parameter; self.value = value }
}

public struct AdaptiveMeasurementOptions: Codable, Equatable, Sendable {
    public var limits: AdaptiveMeasurementLimits
    public var locks: [AdaptiveParameterLock]
    public init(limits: AdaptiveMeasurementLimits = .init(), locks: [AdaptiveParameterLock] = []) {
        self.limits = limits; self.locks = locks
    }
    public func isLocked(_ parameter: AdaptiveParameter) -> Bool { locks.contains { $0.parameter == parameter } }
    public func lockValue(_ parameter: AdaptiveParameter) -> String? { locks.first { $0.parameter == parameter }?.value }
}

public struct AdaptiveRule: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let priority: Int
    public let condition: String
    public let action: String
    public init(id: String, priority: Int, condition: String, action: String) {
        self.id = id; self.priority = priority; self.condition = condition; self.action = action
    }
}

/// Deterministic, normalized planning trade-offs. These values are decision
/// aids, not a probability that a measurement is correct.
public struct AdaptiveScore: Codable, Equatable, Sendable {
    public let confidence: Double
    public let durationEfficiency: Double
    public let loudnessSafety: Double
    public let ambiguityRisk: Double
    public let driftSensitivity: Double
    public let environmentalRobustness: Double
    public let total: Double

    public init(confidence: Double, durationEfficiency: Double, loudnessSafety: Double,
                ambiguityRisk: Double, driftSensitivity: Double,
                environmentalRobustness: Double, total: Double) {
        self.confidence = confidence
        self.durationEfficiency = durationEfficiency
        self.loudnessSafety = loudnessSafety
        self.ambiguityRisk = ambiguityRisk
        self.driftSensitivity = driftSensitivity
        self.environmentalRobustness = environmentalRobustness
        self.total = total
    }
}

public struct AdaptiveDecision: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let objective: MeasurementObjective
    public let signalConfiguration: TestSignalConfiguration
    public let searchRange: ClosedRange<Int64>
    public let repetitionCount: Int
    public let markerSpacing: DurationSeconds
    public let normalizationEnabled: Bool
    public let highPassEnabled: Bool
    public let correlationMode: String
    public let minimumAcceptableConfidence: Double
    public let retryStrategy: RetryStrategy
    public let reasons: [DecisionReason]
    public let alternatives: [String]
    public let unknownInputs: [String]

    public init(id: UUID = UUID(), objective: MeasurementObjective, signalConfiguration: TestSignalConfiguration,
                searchRange: ClosedRange<Int64>, repetitionCount: Int, markerSpacing: DurationSeconds,
                normalizationEnabled: Bool, highPassEnabled: Bool, correlationMode: String,
                minimumAcceptableConfidence: Double, retryStrategy: RetryStrategy,
                reasons: [DecisionReason], alternatives: [String], unknownInputs: [String]) {
        self.id = id; self.objective = objective; self.signalConfiguration = signalConfiguration
        self.searchRange = searchRange; self.repetitionCount = repetitionCount; self.markerSpacing = markerSpacing
        self.normalizationEnabled = normalizationEnabled; self.highPassEnabled = highPassEnabled
        self.correlationMode = correlationMode; self.minimumAcceptableConfidence = minimumAcceptableConfidence
        self.retryStrategy = retryStrategy; self.reasons = reasons; self.alternatives = alternatives; self.unknownInputs = unknownInputs
    }
}

public struct DecisionReason: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let rule: AdaptiveRule
    public let inputs: [String: String]
    public let outcome: String
    public init(id: UUID = UUID(), rule: AdaptiveRule, inputs: [String: String], outcome: String) {
        self.id = id; self.rule = rule; self.inputs = inputs; self.outcome = outcome
    }
}

public enum RetryAdjustment: String, Codable, CaseIterable, Sendable {
    case extendDuration, increaseRepetition, lowerAmplitude, raiseAmplitudeWithinLimit, widenSearchRange
    case changeSeed, useAperiodicSignal, extendPostRoll, requestHardwareGain
}

public struct RetryStrategy: Codable, Equatable, Sendable {
    public let maximumAttempts: Int
    public let adjustments: [RetryAdjustment]
    public let stopWhenNoImprovement: Bool
    public init(maximumAttempts: Int, adjustments: [RetryAdjustment], stopWhenNoImprovement: Bool = true) {
        self.maximumAttempts = maximumAttempts; self.adjustments = adjustments; self.stopWhenNoImprovement = stopWhenNoImprovement
    }
}

public enum PlannerConfidence: String, Codable, CaseIterable, Sendable { case high, medium, low }

public struct PlannerDiagnostics: Codable, Equatable, Sendable {
    public let confidence: PlannerConfidence
    public let score: AdaptiveScore
    public let appliedRules: [AdaptiveRule]
    public let lockedParameters: [AdaptiveParameter]
    public let constraintsRespected: Bool
    public let summary: String
    public init(confidence: PlannerConfidence, score: AdaptiveScore = AdaptiveScore(confidence: 0, durationEfficiency: 0,
                                                                                     loudnessSafety: 0, ambiguityRisk: 0,
                                                                                     driftSensitivity: 0, environmentalRobustness: 0,
                                                                                     total: 0), appliedRules: [AdaptiveRule],
                lockedParameters: [AdaptiveParameter], constraintsRespected: Bool, summary: String) {
        self.confidence = confidence; self.appliedRules = appliedRules; self.lockedParameters = lockedParameters
        self.score = score; self.constraintsRespected = constraintsRespected; self.summary = summary
    }
}

public struct AdaptivePlan: Codable, Equatable, Sendable {
    public let decision: AdaptiveDecision
    public let diagnostics: PlannerDiagnostics
}

public enum AdaptivePlannerError: Error, Codable, Equatable, Sendable, LocalizedError {
    case invalidEnvironment(String)
    case lockedValueInvalid(AdaptiveParameter, String)
    public var errorDescription: String? {
        switch self { case let .invalidEnvironment(message): message; case let .lockedValueInvalid(parameter, value): "Locked \(parameter.rawValue) value is invalid: \(value)." }
    }
}

public struct AdaptiveMeasurementPlanner: Sendable {
    public let rules: [AdaptiveRule]
    public init(rules: [AdaptiveRule] = AdaptiveMeasurementPlanner.defaultRules) { self.rules = rules.sorted { $0.priority < $1.priority } }

    public func plan(objective: MeasurementObjective, environment: MeasurementEnvironment,
                     options: AdaptiveMeasurementOptions = .init(), probe: ProbeMeasurement? = nil) throws -> AdaptivePlan {
        let measured = probe?.applying(to: environment) ?? environment
        guard measured.clippingRatio.isFinite, measured.clippingRatio >= 0, measured.clippingRatio <= 1 else {
            throw AdaptivePlannerError.invalidEnvironment("Clipping ratio must be between zero and one.")
        }
        let rate = measured.sampleRate
        let defaults = base(objective: objective, sampleRate: rate)
        var kind = defaults.kind
        var duration = defaults.duration
        var amplitude = defaults.amplitude
        var preRoll = defaults.preRollSilence
        var postRoll = defaults.postRollSilence
        var repetitions = defaults.repetitions
        var spacing = defaults.spacing
        var search = defaults.search
        var highPass = defaults.highPass
        let correlation = defaults.correlation
        let minimumConfidence = defaults.minimumConfidence
        var reasons: [DecisionReason] = []

        func apply(_ id: String, _ condition: String, _ action: String, inputs: [String: String], outcome: String) {
            let rule = rules.first { $0.id == id } ?? AdaptiveRule(id: id, priority: 100, condition: condition, action: action)
            reasons.append(DecisionReason(rule: rule, inputs: inputs, outcome: outcome))
        }
        if let snr = measured.signalToNoiseRatio, snr < 12 {
            duration = max(duration, (try? DurationSeconds(2)) ?? duration); repetitions = max(repetitions, 3)
            kind = .maximumLengthSequence; highPass = true
            apply("noise", "SNR below 12 dB", "Lengthen and repeat a noise-like probe", inputs: ["snrDb": String(format: "%.2f", snr)], outcome: "MLS, 2 s, three repetitions")
        }
        if measured.hasAmbiguousPeaks {
            kind = .logarithmicSweep; repetitions = max(repetitions, 2); search = narrowedSearch(measured: measured, fallback: search)
            apply("ambiguity", "Similar peaks were observed", "Prefer an aperiodic sweep and narrower search", inputs: ["ambiguous": "true"], outcome: "Log sweep and constrained lag range")
        }
        if measured.clippingRatio > 0 {
            amplitude = min(amplitude, 0.25)
            apply("clipping", "Clipping was observed", "Lower software amplitude without hiding clipping", inputs: ["clippingRatio": String(measured.clippingRatio)], outcome: "Amplitude reduced to safe level")
        } else if let rms = measured.inputRMS, rms < 0.01, options.limits.allowAutomaticAmplitude {
            amplitude = min(options.limits.maximumAmplitude, max(amplitude, 0.65))
            apply("weak", "Input RMS is below 0.01", "Raise software amplitude within the user limit", inputs: ["inputRMS": String(rms)], outcome: "Amplitude raised conservatively")
        }
        if measured.hasLongTail {
            postRoll = max(postRoll, (try? DurationSeconds(1.5)) ?? postRoll); spacing = max(spacing, (try? DurationSeconds(0.75)) ?? spacing)
            apply("tail", "A long correlation tail was observed", "Separate markers and extend capture", inputs: ["longTail": "true"], outcome: "Longer post-roll and marker spacing")
        }
        if let rough = measured.roughDelaySamples, abs(rough - search.lowerBound) < 32 || abs(search.upperBound - rough) < 32 {
            search = (rough - 2_048)...(rough + 2_048)
            postRoll = max(postRoll, (try? DurationSeconds(0.5)) ?? postRoll)
            apply("boundary", "Probe peak is near the search edge", "Widen search and post-roll", inputs: ["roughDelaySamples": String(rough)], outcome: "Search window widened")
        }
        if measured.narrowBand { highPass = false; apply("band", "Path appears narrow-band", "Preserve low frequency content", inputs: ["narrowBand": "true"], outcome: "High-pass disabled") }
        let maximumDuration = options.limits.maximumDuration
        if duration > maximumDuration { duration = maximumDuration; apply("limit.duration", "Requested duration exceeds user limit", "Clamp duration", inputs: ["maximumSeconds": String(maximumDuration.value)], outcome: "Duration clamped") }
        if amplitude > options.limits.maximumAmplitude { amplitude = options.limits.maximumAmplitude; apply("limit.amplitude", "Requested amplitude exceeds user limit", "Clamp amplitude", inputs: ["maximumAmplitude": String(options.limits.maximumAmplitude)], outcome: "Amplitude clamped") }
        if preRoll > options.limits.maximumPreRoll { preRoll = options.limits.maximumPreRoll }
        if postRoll > options.limits.maximumPostRoll { postRoll = options.limits.maximumPostRoll }
        if options.isLocked(.signalKind), let value = options.lockValue(.signalKind) {
            guard let locked = SignalKind(rawValue: value) else { throw AdaptivePlannerError.lockedValueInvalid(.signalKind, value) }; kind = locked
        }
        if options.isLocked(.amplitude), let value = options.lockValue(.amplitude) {
            guard let locked = Double(value), locked.isFinite, locked >= 0, locked <= Double(options.limits.maximumAmplitude) else { throw AdaptivePlannerError.lockedValueInvalid(.amplitude, value) }; amplitude = Float(locked)
        }
        if options.isLocked(.duration), let value = options.lockValue(.duration) {
            guard let locked = Double(value), let seconds = try? DurationSeconds(locked), seconds <= maximumDuration else { throw AdaptivePlannerError.lockedValueInvalid(.duration, value) }; duration = seconds
        }
        let configuration = TestSignalConfiguration(kind: kind, sampleRate: rate, duration: duration,
            startFrequencyHertz: 20, endFrequencyHertz: min(20_000, rate.hertz / 2 - 1), amplitude: amplitude,
            preRollSilence: preRoll, postRollSilence: postRoll, fadeIn: .fiftyMilliseconds, fadeOut: .fiftyMilliseconds,
            channelCount: 1, deterministicSeed: measured.hasAmbiguousPeaks ? 0xA0D1_01A5_1A8B_1E5E : 0xA0D1_01A5_1A8B_1E5D)
        let retry = options.limits.allowAutomaticRetry ? RetryStrategy(maximumAttempts: options.limits.maximumRetries,
            adjustments: measured.clippingRatio > 0 ? [.lowerAmplitude, .requestHardwareGain] : [.extendDuration, .increaseRepetition, .changeSeed]) : RetryStrategy(maximumAttempts: 0, adjustments: [])
        let decision = AdaptiveDecision(objective: objective, signalConfiguration: configuration, searchRange: search,
            repetitionCount: repetitions, markerSpacing: spacing, normalizationEnabled: true, highPassEnabled: highPass,
            correlationMode: correlation, minimumAcceptableConfidence: minimumConfidence, retryStrategy: retry,
            reasons: reasons, alternatives: ["Use manual mode to lock every parameter.", "Use a shorter impulse for a clean loopback."], unknownInputs: measured.inputRMS == nil ? ["inputRMS", "noiseFloorRMS"] : [])
        let confidence: PlannerConfidence = probe == nil ? .medium : (reasons.isEmpty ? .high : .medium)
        let score = score(objective: objective, environment: measured, configuration: configuration,
                          repetitionCount: repetitions, options: options)
        let diagnostics = PlannerDiagnostics(confidence: confidence, score: score, appliedRules: reasons.map(\.rule), lockedParameters: options.locks.map(\.parameter), constraintsRespected: amplitude <= options.limits.maximumAmplitude && duration <= maximumDuration, summary: "Planner used deterministic rules and a weighted heuristic score; no model inference was used.")
        return AdaptivePlan(decision: decision, diagnostics: diagnostics)
    }

    private func score(objective: MeasurementObjective, environment: MeasurementEnvironment,
                       configuration: TestSignalConfiguration, repetitionCount: Int,
                       options: AdaptiveMeasurementOptions) -> AdaptiveScore {
        let snr = environment.signalToNoiseRatio.map { min(1, max(0, ($0 + 6) / 36)) } ?? 0.5
        let clipping = environment.clippingRatio > 0 ? 0.15 : 1.0
        let confidence = snr * clipping
        let durationEfficiency = min(1, max(0, 1 - configuration.duration.value / max(options.limits.maximumDuration.value, 0.001)))
        let loudnessSafety = min(1, max(0, 1 - Double(configuration.amplitude) / max(Double(options.limits.maximumAmplitude), 0.001)))
        let ambiguityRisk = environment.hasAmbiguousPeaks ? 0.2 : 1.0
        let driftSensitivity = objective == .clockDrift ? 1.0 : (environment.driftPPM == nil ? 0.7 : 0.5)
        let environmentalRobustness = min(1, max(0, snr * (repetitionCount > 1 ? 1 : 0.75) * (environment.hasLongTail ? 0.8 : 1)))
        let total = confidence * 0.30 + durationEfficiency * 0.15 + loudnessSafety * 0.15 +
            ambiguityRisk * 0.15 + driftSensitivity * 0.10 + environmentalRobustness * 0.15
        return AdaptiveScore(confidence: confidence, durationEfficiency: durationEfficiency,
                             loudnessSafety: loudnessSafety, ambiguityRisk: ambiguityRisk,
                             driftSensitivity: driftSensitivity, environmentalRobustness: environmentalRobustness,
                             total: total)
    }

    private struct Defaults { let kind: SignalKind; let duration: DurationSeconds; let amplitude: Float; let preRollSilence: DurationSeconds; let postRollSilence: DurationSeconds; let repetitions: Int; let spacing: DurationSeconds; let search: ClosedRange<Int64>; let highPass: Bool; let correlation: String; let minimumConfidence: Double }
    private func base(objective: MeasurementObjective, sampleRate: SampleRate) -> Defaults {
        let duration = (try? DurationSeconds(objective == .quick ? 0.5 : objective == .highPrecision || objective == .noisyEnvironment ? 3 : 1.5)) ?? .oneTenthSecond
        let kind: SignalKind = objective == .pluginAnalysis ? .impulse : objective == .noisyEnvironment ? .maximumLengthSequence : .logarithmicSweep
        let range: Int64 = objective == .longDelayPath ? 480_000 : 96_000
        return Defaults(kind: kind, duration: duration, amplitude: objective == .quick ? 0.35 : 0.5, preRollSilence: .fiftyMilliseconds, postRollSilence: .oneTenthSecond, repetitions: objective == .highPrecision || objective == .clockDrift ? 5 : 1, spacing: .oneTenthSecond, search: (-range)...range, highPass: objective != .pluginAnalysis, correlation: objective == .quick ? "direct-or-fft" : "fft", minimumConfidence: objective == .quick ? 0.65 : 0.8)
    }
    private func narrowedSearch(measured: MeasurementEnvironment, fallback: ClosedRange<Int64>) -> ClosedRange<Int64> {
        guard let rough = measured.roughDelaySamples else { return fallback }
        return (rough - 4_096)...(rough + 4_096)
    }

    public static let defaultRules: [AdaptiveRule] = [
        AdaptiveRule(id: "noise", priority: 10, condition: "SNR < 12 dB", action: "Use longer MLS/repetition"),
        AdaptiveRule(id: "ambiguity", priority: 20, condition: "Similar peaks", action: "Use aperiodic sweep and narrow search"),
        AdaptiveRule(id: "clipping", priority: 30, condition: "Clipping ratio > 0", action: "Lower software amplitude"),
        AdaptiveRule(id: "weak", priority: 40, condition: "Input RMS < 0.01", action: "Raise amplitude within limit"),
        AdaptiveRule(id: "boundary", priority: 50, condition: "Peak near boundary", action: "Widen search range"),
        AdaptiveRule(id: "tail", priority: 60, condition: "Long tail", action: "Extend marker spacing/post-roll")
    ]
}
