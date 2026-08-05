import AudioLinkCore
import Foundation

public enum FrequencyBandKind: String, Codable, CaseIterable, Sendable { case broadband, octave, oneThirdOctave }
public struct FrequencyBand: Codable, Equatable, Hashable, Sendable {
    public let centerHertz: Double
    public let lowerHertz: Double
    public let upperHertz: Double
    public let kind: FrequencyBandKind
    public init(centerHertz: Double, lowerHertz: Double, upperHertz: Double, kind: FrequencyBandKind) throws {
        guard centerHertz > 0, lowerHertz > 0, upperHertz > lowerHertz, centerHertz.isFinite, lowerHertz.isFinite, upperHertz.isFinite else { throw SpatialValidationError.invalidFrequencyBand }
        self.centerHertz = centerHertz; self.lowerHertz = lowerHertz; self.upperHertz = upperHertz; self.kind = kind
    }
    public static func octave(centerHertz: Double) throws -> FrequencyBand { try FrequencyBand(centerHertz: centerHertz, lowerHertz: centerHertz / sqrt(2), upperHertz: centerHertz * sqrt(2), kind: .octave) }
    public static func oneThirdOctave(centerHertz: Double) throws -> FrequencyBand { let factor = pow(2.0, 1.0 / 6.0); return try FrequencyBand(centerHertz: centerHertz, lowerHertz: centerHertz / factor, upperHertz: centerHertz * factor, kind: .oneThirdOctave) }
}

public struct FrequencyBandMeasurement: Codable, Equatable, Sendable {
    public let band: FrequencyBand
    public let levelDecibels: Double?
    public let valid: Bool
    public let explanation: String
    public init(band: FrequencyBand, levelDecibels: Double?, valid: Bool, explanation: String) { self.band = band; self.levelDecibels = levelDecibels; self.valid = valid; self.explanation = explanation }
}

public struct FrequencyBandAnalyzer: Sendable {
    public init() {}
    public func analyze(samples: [Float], sampleRate: SampleRate, bands: [FrequencyBand]) throws -> [FrequencyBandMeasurement] {
        guard !samples.isEmpty, !bands.isEmpty else { throw SpatialValidationError.invalidIR }
        let finite = samples.map { $0.isFinite ? Double($0) : 0 }
        let maxFrequency = sampleRate.hertz / 2
        return bands.map { band in
            guard band.lowerHertz < maxFrequency else { return FrequencyBandMeasurement(band: band, levelDecibels: nil, valid: false, explanation: "Band is above Nyquist.") }
            let upper = min(band.upperHertz, maxFrequency)
            let binCount = max(1, finite.count / 2)
            var energy = 0.0; var included = 0
            for bin in 0...binCount {
                let frequency = Double(bin) * sampleRate.hertz / Double(finite.count)
                guard frequency >= band.lowerHertz, frequency <= upper else { continue }
                var real = 0.0; var imaginary = 0.0
                for (index, sample) in finite.enumerated() {
                    let phase = 2 * Double.pi * frequency * Double(index) / sampleRate.hertz
                    real += sample * cos(phase); imaginary -= sample * sin(phase)
                }
                energy += (real * real + imaginary * imaginary) / Double(finite.count * finite.count); included += 1
            }
            guard included > 0 else { return FrequencyBandMeasurement(band: band, levelDecibels: nil, valid: false, explanation: "No FFT bin falls inside this band at the selected duration.") }
            return FrequencyBandMeasurement(band: band, levelDecibels: 10 * log10(max(energy / Double(included), 1e-20)), valid: true, explanation: "Standard-inspired band energy; no IEC/ISO compliance is claimed.")
        }
    }
}
