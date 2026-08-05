import AudioLinkCore
import Foundation

public struct MeasurementHistoryStatisticsCalculator: Sendable {
    public init() {}

    public func statistics(for runs: [MeasurementHistoryRun]) -> MeasurementStatistics? {
        let ordered = runs
            .compactMap { run -> (Date, DelayEstimate)? in
                run.delayEstimate.map { (run.createdAt, $0) }
            }
            .sorted { $0.0 < $1.0 }
        guard let first = ordered.first else { return nil }
        let sampleRate = first.1.sampleRate
        let sampleValues = ordered.map { pair in
            (pair.1.fractionalSampleOffset ?? Double(pair.1.sampleOffset.rawValue))
                / pair.1.sampleRate.hertz * sampleRate.hertz
        }
        let sorted = sampleValues.sorted()
        let count = sorted.count
        let mean = sorted.reduce(0, +) / Double(count)
        let median: Double
        if count.isMultiple(of: 2) {
            median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        } else {
            median = sorted[count / 2]
        }
        let variance = sorted.reduce(0) { partial, value in
            let difference = value - mean
            return partial + difference * difference
        } / Double(count)
        let jitter = (try? DurationSeconds(sqrt(variance) / sampleRate.hertz)) ?? .zero
        return MeasurementStatistics(
            sampleSize: count,
            meanDelay: SampleCount(rawValue: Int64(mean.rounded())),
            medianDelay: SampleCount(rawValue: Int64(median.rounded())),
            minimumDelay: SampleCount(rawValue: Int64((sorted.first ?? 0).rounded())),
            maximumDelay: SampleCount(rawValue: Int64((sorted.last ?? 0).rounded())),
            jitterStandardDeviation: jitter,
            clockDrift: drift(for: ordered)
        )
    }

    private func drift(for ordered: [(Date, DelayEstimate)]) -> PartsPerMillion? {
        guard ordered.count >= 2, let origin = ordered.first?.0 else { return nil }
        let points = ordered.map { date, delay in
            (
                x: date.timeIntervalSince(origin),
                y: (delay.fractionalSampleOffset ?? Double(delay.sampleOffset.rawValue))
                    / delay.sampleRate.hertz
            )
        }
        let meanX = points.map(\.x).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.y).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        let denominator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        guard denominator > 0 else { return nil }
        let partsPerMillion = numerator / denominator * 1_000_000
        guard partsPerMillion.isFinite else { return nil }
        return PartsPerMillion(rawValue: partsPerMillion)
    }
}
