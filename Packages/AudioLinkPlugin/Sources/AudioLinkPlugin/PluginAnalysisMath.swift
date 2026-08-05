import Foundation

/// Small, deterministic offline helpers used by the isolated runner. They
/// intentionally operate on bounded arrays; realtime callbacks never call
/// these routines.
public enum PluginAnalysisMath {
    public static func frequencyResponse(input: [Float], output: [Float], sampleRate: Double, frequencies: [Double]) -> PluginFrequencyResponse {
        let magnitudes = frequencies.map { frequency -> Double in
            let inputMagnitude = magnitude(of: input, frequency: frequency, sampleRate: sampleRate)
            let outputMagnitude = magnitude(of: output, frequency: frequency, sampleRate: sampleRate)
            guard inputMagnitude > 1e-12 else { return -120 }
            return 20 * log10(max(1e-12, outputMagnitude / inputMagnitude))
        }
        return PluginFrequencyResponse(frequenciesHertz: frequencies, magnitudeDB: magnitudes)
    }

    public static func phaseResponse(input: [Float], output: [Float], sampleRate: Double, frequencies: [Double]) -> PluginPhaseResponse {
        // A raw atan2 difference is wrapped to [-π, π] and produces large
        // false group-delay spikes whenever the response crosses a branch
        // cut.  Unwrap the response phase before differentiating it.
        let rawPhases = frequencies.map { frequency in phase(of: output, frequency: frequency, sampleRate: sampleRate) - phase(of: input, frequency: frequency, sampleRate: sampleRate) }
        var phases: [Double] = []
        phases.reserveCapacity(rawPhases.count)
        for value in rawPhases {
            guard !phases.isEmpty else {
                phases.append(value)
                continue
            }
            let previousRaw = rawPhases[phases.count - 1]
            let previous = phases[phases.count - 1]
            var delta = value - previousRaw
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            phases.append(previous + delta)
        }
        var delays: [Double] = []; delays.reserveCapacity(phases.count)
        for index in phases.indices {
            guard index > 0, frequencies[index] != frequencies[index - 1] else { delays.append(0); continue }
            let phaseDifference = phases[index] - phases[index - 1]
            let frequencyDifference = frequencies[index] - frequencies[index - 1]
            delays.append(-phaseDifference / (2 * Double.pi * frequencyDifference))
        }
        return PluginPhaseResponse(frequenciesHertz: frequencies, phaseRadians: phases, groupDelaySeconds: delays)
    }

    public static func totalHarmonicDistortion(samples: [Float], sampleRate: Double, fundamentalHertz: Double, harmonicCount: Int = 5) -> PluginDistortionResult {
        let fundamental = magnitude(of: samples, frequency: fundamentalHertz, sampleRate: sampleRate)
        guard fundamental > 1e-12 else { return PluginDistortionResult(thdRatio: 0, harmonics: [:]) }
        var harmonics: [Int: Double] = [:]; var sum = 0.0
        for harmonic in 2...max(2, harmonicCount) { let value = magnitude(of: samples, frequency: fundamentalHertz * Double(harmonic), sampleRate: sampleRate) / fundamental; harmonics[harmonic] = value; sum += value * value }
        return PluginDistortionResult(thdRatio: sqrt(sum), harmonics: harmonics)
    }

    public static func tailTime(samples: [Float], sampleRate: Double, threshold: Float = 0.001) -> Double? {
        guard let last = samples.lastIndex(where: { abs($0) >= threshold }), sampleRate > 0 else { return nil }
        return Double(last) / sampleRate
    }

    private static func components(of samples: [Float], frequency: Double, sampleRate: Double) -> (Double, Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return (0, 0) }
        var real = 0.0; var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(max(1, samples.count)))
            let angle = 2 * .pi * frequency * Double(index) / sampleRate
            real += Double(sample) * window * cos(angle)
            imaginary -= Double(sample) * window * sin(angle)
        }
        return (real, imaginary)
    }
    private static func magnitude(of samples: [Float], frequency: Double, sampleRate: Double) -> Double { let pair = components(of: samples, frequency: frequency, sampleRate: sampleRate); return hypot(pair.0, pair.1) / max(1, Double(samples.count) * 0.5) }
    private static func phase(of samples: [Float], frequency: Double, sampleRate: Double) -> Double { let pair = components(of: samples, frequency: frequency, sampleRate: sampleRate); return atan2(pair.1, pair.0) }
}
