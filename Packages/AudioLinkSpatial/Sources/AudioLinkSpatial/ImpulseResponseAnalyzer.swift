import AudioLinkCore
import Foundation

public struct InverseSweepConfiguration: Codable, Equatable, Sendable {
    public let regularization: Double
    public let windowStartSeconds: Double
    public let windowEndSeconds: Double?
    public init(regularization: Double = 1e-6, windowStartSeconds: Double = 0, windowEndSeconds: Double? = nil) { self.regularization = regularization; self.windowStartSeconds = windowStartSeconds; self.windowEndSeconds = windowEndSeconds }
}

public struct ImpulseResponseAnalyzer: Sendable {
    public init() {}

    /// A deterministic matched-filter/deconvolution fallback. It is intentionally
    /// regularized and bounded; production-grade calibrated IR work should use
    /// the recorded inverse filter and is not claimed to be IEC/ISO compliant.
    public func extractImpulseResponse(sweep: [Float], recording: [Float], sampleRate: SampleRate, configuration: InverseSweepConfiguration = .init()) throws -> [Float] {
        guard !sweep.isEmpty, !recording.isEmpty, configuration.regularization.isFinite, configuration.regularization >= 0 else { throw SpatialValidationError.invalidIR }
        let energy = sweep.reduce(0) { $0 + Double($1) * Double($1) } + configuration.regularization
        guard energy.isFinite, energy > 0 else { throw SpatialValidationError.invalidIR }
        let maxLag = min(recording.count, max(1, sweep.count * 2))
        var output = [Float](repeating: 0, count: maxLag)
        for lag in 0..<maxLag {
            let overlap = min(sweep.count, recording.count - lag)
            guard overlap > 0 else { continue }
            var sum = 0.0
            for index in 0..<overlap { sum += Double(recording[lag + index]) * Double(sweep[index]) }
            output[lag] = Float(sum / energy)
        }
        let start = max(0, Int((configuration.windowStartSeconds * sampleRate.hertz).rounded()))
        let end = min(output.count, configuration.windowEndSeconds.map { Int(($0 * sampleRate.hertz).rounded()) } ?? output.count)
        guard start < end else { throw SpatialValidationError.invalidIR }
        if start == 0 && end == output.count { return output }
        return Array(output[start..<end])
    }

    public func analyze(samples: [Float], sampleRate: SampleRate, noiseSamples: [Float] = [], directWindowSeconds: Double = 0.002) throws -> AcousticMetricSet {
        guard !samples.isEmpty,
              sampleRate.hertz.isFinite,
              sampleRate.hertz > 0,
              directWindowSeconds.isFinite,
              directWindowSeconds >= 0,
              samples.allSatisfy(\.isFinite),
              noiseSamples.allSatisfy(\.isFinite) else {
            throw SpatialValidationError.invalidIR
        }
        let finite = samples
        let peakIndex = finite.indices.max { abs(finite[$0]) < abs(finite[$1]) } ?? 0
        let peak = abs(Double(finite[peakIndex]))
        let postPeak = finite[peakIndex...]
        let totalEnergy = postPeak.reduce(0) { $0 + Double($1) * Double($1) }
        let noiseEnergy = noiseSamples.reduce(0) { $0 + Double($1) * Double($1) }
        let signalMeanEnergy = noiseSamples.isEmpty ? nil : totalEnergy / Double(max(1, postPeak.count))
        let noiseMeanEnergy = noiseSamples.isEmpty ? nil : noiseEnergy / Double(max(1, noiseSamples.count))
        let snr: Double? = if let signalMeanEnergy, let noiseMeanEnergy, noiseMeanEnergy > 0, signalMeanEnergy > 0 {
            10 * log10(signalMeanEnergy / noiseMeanEnergy)
        } else { nil }
        let edt = decayFit(samples: finite, sampleRate: sampleRate, start: peakIndex, end: min(finite.count, peakIndex + Int(sampleRate.hertz * 0.2)), lowerDB: 0, upperDB: -10, noiseMeanEnergy: noiseMeanEnergy)
        let rt20 = decayFit(samples: finite, sampleRate: sampleRate, start: peakIndex, end: finite.count, lowerDB: -5, upperDB: -25, noiseMeanEnergy: noiseMeanEnergy)
        let rt30 = decayFit(samples: finite, sampleRate: sampleRate, start: peakIndex, end: finite.count, lowerDB: -5, upperDB: -35, noiseMeanEnergy: noiseMeanEnergy)
        let rt60 = decayFit(samples: finite, sampleRate: sampleRate, start: peakIndex, end: finite.count, lowerDB: -5, upperDB: -55, noiseMeanEnergy: noiseMeanEnergy)
        let earlyLimit = min(finite.count, peakIndex + max(1, Int((directWindowSeconds + 0.1) * sampleRate.hertz)))
        let early = (peakIndex + 1..<earlyLimit).compactMap { index -> EarlyReflectionCandidate? in
            let magnitude = abs(Double(finite[index]))
            let left = abs(Double(finite[index - 1]))
            let right = index + 1 < finite.count ? abs(Double(finite[index + 1])) : 0
            let delay = index - peakIndex
            guard delay > 0, magnitude >= left, magnitude > right, magnitude >= peak * 0.2 else { return nil }
            return EarlyReflectionCandidate(delaySeconds: Double(delay) / sampleRate.hertz, relativeLevelDecibels: 20 * log10(max(magnitude / max(peak, 1e-12), 1e-12)), evidence: "Local post-direct sample peak exceeds 20% of the direct peak.")
        }.prefix(12)
        let c50Count = min(postPeak.count, max(1, Int((0.05 * sampleRate.hertz).rounded())))
        let c80Count = min(postPeak.count, max(1, Int((0.08 * sampleRate.hertz).rounded())))
        let energyBefore = postPeak.prefix(c50Count).reduce(0) { $0 + Double($1) * Double($1) }
        let energyBefore80 = postPeak.prefix(c80Count).reduce(0) { $0 + Double($1) * Double($1) }
        let late50 = max(totalEnergy - energyBefore, 1e-20)
        let late80 = max(totalEnergy - energyBefore80, 1e-20)
        let allTime = postPeak.enumerated().reduce(0.0) { $0 + Double($1.offset) / sampleRate.hertz * Double($1.element) * Double($1.element) }
        let denom = max(totalEnergy, 1e-20)
        func metric(_ value: Double?, unit: String, valid: Bool, method: String, explanation: String, confidence: Double = 0.8) -> AcousticMetricValue {
            AcousticMetricValue(value: value, unit: unit, valid: valid && (value?.isFinite ?? false), confidence: valid ? max(0, min(1, confidence)) : 0, method: method, explanation: explanation)
        }
        func decayMetric(_ fit: DecayFit?, unit: String, method: String, range: String) -> AcousticMetricValue {
            metric(fit?.rt60Seconds, unit: unit, valid: fit != nil, method: method, explanation: fit.map {
                let noise = $0.noiseFloorDB.map { "; noise-equivalent floor=\($0.formatted(.number.precision(.fractionLength(1)))) dB" } ?? ""
                return "Energy-decay fit over \(range); R²=\($0.rSquared.formatted(.number.precision(.fractionLength(3)))); dynamic range=\($0.dynamicRangeDB.formatted(.number.precision(.fractionLength(1)))) dB\(noise)."
            } ?? "Invalid: the requested energy-decay range contains too few finite samples, insufficient dynamic range, excessive noise floor, or does not decrease.", confidence: fit?.rSquared ?? 0)
        }
        return AcousticMetricSet(
            peakArrivalTime: metric(Double(peakIndex) / sampleRate.hertz, unit: "seconds", valid: true, method: "absolute peak", explanation: "Largest finite sample; direct-path interpretation is heuristic."),
            directSoundLevel: metric(20 * log10(max(peak, 1e-12)), unit: "dBFS", valid: peak > 0, method: "peak dBFS", explanation: "Digital level, not calibrated SPL."),
            edt: decayMetric(edt, unit: "seconds", method: "Schroeder energy -0 to -10 dB fit", range: "0 to -10 dB"),
            rt20: decayMetric(rt20, unit: "seconds", method: "Schroeder energy -5 to -25 dB fit", range: "-5 to -25 dB"),
            rt30: decayMetric(rt30, unit: "seconds", method: "Schroeder energy -5 to -35 dB fit", range: "-5 to -35 dB"),
            estimatedRT60: decayMetric(rt60, unit: "seconds", method: "Schroeder energy -5 to -55 dB fit", range: "-5 to -55 dB"),
            c50: metric(10 * log10(max(energyBefore, 1e-20) / late50), unit: "dB", valid: totalEnergy > 0, method: "50 ms energy ratio", explanation: "Early-to-late energy ratio after the detected direct sound."),
            c80: metric(10 * log10(max(energyBefore80, 1e-20) / late80), unit: "dB", valid: totalEnergy > 0, method: "80 ms energy ratio", explanation: "Early-to-late energy ratio after the detected direct sound."),
            d50: metric(energyBefore / denom, unit: "fraction", valid: totalEnergy > 0, method: "50 ms early energy fraction", explanation: "Fraction of energy arriving within 50 ms."),
            centerTime: metric(allTime / denom, unit: "seconds", valid: totalEnergy > 0, method: "energy-weighted time", explanation: "Energy centroid after detected direct sound."),
            signalToNoiseRatio: metric(snr, unit: "dB", valid: snr != nil, method: "per-sample energy ratio", explanation: "Requires an explicitly supplied noise segment of comparable duration."),
            earlyReflections: Array(early)
        )
    }

    private func decayFit(samples: [Float], sampleRate: SampleRate, start: Int, end: Int, lowerDB: Double = -5, upperDB: Double = -35, noiseMeanEnergy: Double? = nil) -> DecayFit? {
        guard start >= 0, start < end, end <= samples.count else { return nil }
        let energy = samples[start..<end].map { Double($0) * Double($0) }
        guard let first = energy.first, first > 0 else { return nil }
        var cumulative = [Double](repeating: 0, count: energy.count)
        var running = 0.0
        for index in energy.indices.reversed() { running += energy[index]; cumulative[index] = running }
        guard let total = cumulative.first, total > 0 else { return nil }
        let noiseFloorDB: Double?
        if let noiseMeanEnergy, noiseMeanEnergy.isFinite, noiseMeanEnergy > 0 {
            let noiseEquivalentEnergy = noiseMeanEnergy * Double(energy.count)
            let floor = 10 * log10(max(noiseEquivalentEnergy / total, 1e-20))
            // A fit cannot support a target range that is already below the
            // measured noise floor.  Reject rather than extrapolate through it.
            guard floor < upperDB else { return nil }
            noiseFloorDB = floor
        } else {
            noiseFloorDB = nil
        }
        var points: [(Double, Double)] = []
        for index in cumulative.indices {
            let db = 10 * log10(max(cumulative[index] / total, 1e-20))
            if db <= lowerDB && db >= upperDB { points.append((Double(index) / sampleRate.hertz, db)) }
        }
        guard points.count >= 8 else { return nil }
        let meanX = points.map(\.0).reduce(0, +) / Double(points.count); let meanY = points.map(\.1).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }; let denominator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        guard denominator > 0 else { return nil }; let slope = numerator / denominator
        let residuals = points.map { point in point.1 - (slope * point.0 + (meanY - slope * meanX)) }
        let ssResidual = residuals.reduce(0) { $0 + $1 * $1 }
        let ssTotal = points.reduce(0) { $0 + ($1.1 - meanY) * ($1.1 - meanY) }
        let rSquared = ssTotal > 0 ? max(0, min(1, 1 - ssResidual / ssTotal)) : 0
        let dynamicRangeDB = (points.map(\.1).max() ?? 0) - (points.map(\.1).min() ?? 0)
        guard slope < 0, slope.isFinite, rSquared >= 0.9,
              dynamicRangeDB >= max(3, abs(lowerDB - upperDB) * 0.8) else { return nil }
        return DecayFit(rt60Seconds: 60 / -slope, rSquared: rSquared, dynamicRangeDB: dynamicRangeDB, noiseFloorDB: noiseFloorDB)
    }
}

private struct DecayFit {
    let rt60Seconds: Double
    let rSquared: Double
    let dynamicRangeDB: Double
    let noiseFloorDB: Double?
}
