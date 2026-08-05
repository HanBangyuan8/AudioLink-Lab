import Foundation
import AudioLinkCore

public struct AcousticPathDiagnosticConfiguration: Codable, Equatable, Sendable {
    public let lowInputRMSThreshold: Double
    public let highNoiseFloorDecibels: Double
    public let clippingRatioThreshold: Double
    public let reverberationRatioThreshold: Double
    public let echoRelativeMagnitudeThreshold: Double
    public let channelImbalanceDecibels: Double
    public let partialCaptureRatioThreshold: Double

    public init(
        lowInputRMSThreshold: Double = 0.005,
        highNoiseFloorDecibels: Double = -20,
        clippingRatioThreshold: Double = 0.001,
        reverberationRatioThreshold: Double = 0.35,
        echoRelativeMagnitudeThreshold: Double = 0.25,
        channelImbalanceDecibels: Double = 6,
        partialCaptureRatioThreshold: Double = 0.8
    ) {
        self.lowInputRMSThreshold = lowInputRMSThreshold
        self.highNoiseFloorDecibels = highNoiseFloorDecibels
        self.clippingRatioThreshold = clippingRatioThreshold
        self.reverberationRatioThreshold = reverberationRatioThreshold
        self.echoRelativeMagnitudeThreshold = echoRelativeMagnitudeThreshold
        self.channelImbalanceDecibels = channelImbalanceDecibels
        self.partialCaptureRatioThreshold = partialCaptureRatioThreshold
    }
}

/// Produces evidence-backed, intentionally heuristic observations of the
/// recording path. It never claims to identify a room property with certainty.
public struct AcousticPathDiagnosticsAnalyzer: Sendable {
    public init() {}

    public func analyze(
        reference: AudioSampleBuffer,
        recording: AudioSampleBuffer,
        correlation: CorrelationResult?,
        configuration: AcousticPathDiagnosticConfiguration = .init()
    ) -> AcousticPathDiagnostics {
        let inputRMS = Double(recording.rootMeanSquare)
        let clippingCount = recording.samples.reduce(into: 0) { count, sample in
            if abs(sample) >= 0.999 { count += 1 }
        }
        let clippingRatio = recording.samples.isEmpty ? 0 : Double(clippingCount) / Double(recording.samples.count)
        let primary = correlation?.primaryPeak
        let primaryMagnitude = primary?.magnitude ?? 0
        let noiseFloor = noiseFloorRMS(sequence: correlation?.sequence, primary: primary)
        let snr: Double? = if noiseFloor > 0, primaryMagnitude > 0 {
            20 * log10(primaryMagnitude / noiseFloor)
        } else { nil }
        let reverberationRatio = reverberationRatio(sequence: correlation?.sequence, primary: primary)
        let channelSpread = channelRMSSpread(recording)
        // File-length ratio is not evidence of how much of the reference
        // participated in the selected match.  Use the overlap at the primary
        // lag when available; this remains meaningful for unequal-length and
        // trimmed recordings.
        let coverage: Double? = if let primary, reference.frameCount > 0 {
            min(1, Double(primary.overlapCount.rawValue) / Double(reference.frameCount))
        } else { nil }
        let sampleRate = recording.format.sampleRate.hertz

        var issues: [AcousticDiagnosticIssue] = []
        if clippingRatio >= configuration.clippingRatioThreshold {
            issues.append(.init(
                code: .clippingDetected,
                severity: .warning,
                statement: "Possible clipping was detected in the recording.",
                evidence: "\(clippingCount) of \(recording.samples.count) samples (\(percent(clippingRatio))) are at or above 0.999.",
                recommendation: "Reduce input gain and repeat the measurement."
            ))
        }
        if inputRMS < configuration.lowInputRMSThreshold {
            issues.append(.init(
                code: .lowInputLevel,
                severity: .warning,
                statement: "The input level may be too low for a stable acoustic estimate.",
                evidence: "Recording RMS is \(format(inputRMS)); threshold is \(format(configuration.lowInputRMSThreshold)).",
                recommendation: "Increase the input level without causing clipping."
            ))
        }
        if let snr, snr < configuration.highNoiseFloorDecibels {
            issues.append(.init(
                code: .highNoiseFloor,
                severity: .warning,
                statement: "A high noise floor may be masking the reference signal.",
                evidence: "Estimated correlation SNR is \(format(snr)) dB.",
                recommendation: "Reduce ambient noise or use a stronger, cleanly recorded reference."
            ))
        }
        if reverberationRatio >= configuration.reverberationRatioThreshold {
            issues.append(.init(
                code: .possibleReverberation,
                severity: .information,
                statement: "Possible reverberation is present around the correlation peak.",
                evidence: "Local correlation-tail energy is \(percent(reverberationRatio)) of the peak neighborhood.",
                recommendation: "Try a shorter acoustic path or inspect the correlation plot before accepting the result."
            ))
        }
        let echoes = echoCandidates(sequence: correlation?.sequence, primary: primary, sampleRate: sampleRate, threshold: configuration.echoRelativeMagnitudeThreshold)
        if !echoes.isEmpty {
            issues.append(.init(
                code: .multipleEchoes,
                severity: .warning,
                statement: "Possible multiple echoes or repeated-path responses were found.",
                evidence: "\(echoes.count) secondary local peak(s) exceed \(percent(configuration.echoRelativeMagnitudeThreshold)) of the primary magnitude.",
                recommendation: "Review candidate peaks and repeat with a quieter or less reflective setup."
            ))
            let early = echoes.filter { $0.delayMilliseconds > 0 && $0.delayMilliseconds <= 50 }
            if !early.isEmpty {
                issues.append(.init(
                    code: .earlyReflectionCandidate,
                    severity: .information,
                    statement: "Possible early reflection candidates were found.",
                    evidence: "Secondary peaks occur within 50 ms of the selected peak.",
                    recommendation: "Inspect the peak detail view; this is a heuristic acoustic-path clue."
                ))
            }
        }
        if let channelSpread, channelSpread >= configuration.channelImbalanceDecibels {
            issues.append(.init(
                code: .channelImbalance,
                severity: .warning,
                statement: "The recording channels may be imbalanced.",
                evidence: "Channel RMS spread is \(format(channelSpread)) dB.",
                recommendation: "Check channel gain and select the intended input channel."
            ))
        }
        if let primary, primary.value < 0 {
            issues.append(.init(
                code: .polarityInversion,
                severity: .information,
                statement: "The response may be polarity-inverted.",
                evidence: "The selected correlation peak is signed \(format(primary.value)).",
                recommendation: "Check polarity settings; inversion is not automatically treated as failure."
            ))
        }
        if let coverage, coverage < configuration.partialCaptureRatioThreshold {
            issues.append(.init(
                code: .partialSignalCapture,
                severity: .warning,
                statement: "The recording may contain only a partial capture of the reference.",
                evidence: "Only \(percent(coverage)) of the reference frames overlap the selected correlation peak.",
                recommendation: "Increase post-roll or ensure recording starts before playback."
            ))
        }

        let metrics = AcousticPathDiagnosticMetrics(
            inputRMS: inputRMS,
            noiseFloorRMS: noiseFloor,
            estimatedSignalToNoiseDecibels: snr,
            clippingRatio: clippingRatio,
            reverberationRatio: reverberationRatio,
            channelRMSSpreadDecibels: channelSpread,
            referenceCoverageRatio: coverage,
            primaryPeakSignedAmplitude: primary?.value
        )
        let summary = issues.isEmpty
            ? "No heuristic acoustic-path warnings were triggered."
            : issues.map(\.statement).joined(separator: " ")
        return AcousticPathDiagnostics(metrics: metrics, issues: issues, earlyReflections: echoes.filter { $0.delayMilliseconds > 0 && $0.delayMilliseconds <= 50 }, evidenceSummary: summary)
    }

    private func noiseFloorRMS(sequence: CorrelationSequence?, primary: CorrelationPeak?) -> Double {
        guard let sequence, !sequence.values.isEmpty else { return 0 }
        let values = sequence.values
        let primaryIndex = primary.map { Int($0.lag.rawValue - sequence.firstLag) }
        var filtered: [Double] = []
        filtered.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if let primaryIndex, abs(index - primaryIndex) <= 8 { continue }
            filtered.append(Double(value) * Double(value))
        }
        return filtered.isEmpty ? 0 : sqrt(filtered.reduce(0, +) / Double(filtered.count))
    }

    private func reverberationRatio(sequence: CorrelationSequence?, primary: CorrelationPeak?) -> Double {
        guard let sequence, let primary, !sequence.values.isEmpty else { return 0 }
        let values = sequence.values
        let center = Int(primary.lag.rawValue - sequence.firstLag)
        guard center >= 0, center < values.count else { return 0 }
        let radius = min(128, max(16, values.count / 20))
        let local = values[max(0, center - radius)...min(values.count - 1, center + radius)]
        let total = local.reduce(0) { $0 + Double(abs($1)) }
        let peak = max(1e-12, primary.magnitude)
        return min(1, max(0, (total - peak) / (Double(local.count) * peak)))
    }

    private func echoCandidates(
        sequence: CorrelationSequence?,
        primary: CorrelationPeak?,
        sampleRate: Double,
        threshold: Double
    ) -> [EarlyReflectionCandidate] {
        guard let sequence, let primary, sequence.values.count >= 3 else { return [] }
        let primaryIndex = Int(primary.lag.rawValue - sequence.firstLag)
        let minimumSeparation = 8
        var candidates: [EarlyReflectionCandidate] = []
        for index in 1..<(sequence.values.count - 1) where abs(index - primaryIndex) >= minimumSeparation {
            let magnitude = abs(Double(sequence.values[index]))
            guard magnitude >= primary.magnitude * threshold,
                  magnitude >= abs(Double(sequence.values[index - 1])),
                  magnitude >= abs(Double(sequence.values[index + 1])) else { continue }
            let lag = sequence.firstLag + Int64(index)
            let delta = lag - primary.lag.rawValue
            candidates.append(.init(
                lagSamples: Int(delta),
                delayMilliseconds: Double(delta) / sampleRate * 1_000,
                relativeMagnitude: primary.magnitude > 0 ? magnitude / primary.magnitude : 0,
                evidence: "Local peak at lag \(lag) has magnitude \(format(magnitude))."
            ))
        }
        return candidates.sorted { $0.relativeMagnitude > $1.relativeMagnitude }.prefix(12).map { $0 }
    }

    private func channelRMSSpread(_ buffer: AudioSampleBuffer) -> Double? {
        guard buffer.channelCount > 1, buffer.frameCount > 0 else { return nil }
        var values: [Double] = []
        for channel in 0..<buffer.channelCount {
            guard let channelSamples = try? buffer.withUnsafeChannelSamples(channel: channel, { Array($0) }) else { continue }
            let sum = channelSamples.reduce(0) { $0 + Double($1) * Double($1) }
            values.append(sqrt(sum / Double(channelSamples.count)))
        }
        guard let minimum = values.min(), let maximum = values.max(), minimum > 0 else { return nil }
        return 20 * log10(maximum / minimum)
    }

    private func format(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(3))) }
    private func percent(_ value: Double) -> String { (value * 100).formatted(.number.precision(.fractionLength(2))) + "%" }
}
