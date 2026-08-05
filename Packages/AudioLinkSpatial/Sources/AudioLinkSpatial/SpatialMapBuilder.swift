import Foundation

public struct SpatialMapBuilder: Sendable {
    public init() {}
    public func map(metricName: String, samples: [SpatialMapSample], interpolate: Bool = false, grid: [SpatialCoordinate] = []) -> SpatialMap {
        let valid = samples.filter { $0.valid && $0.metric?.isFinite == true }
        guard interpolate, valid.count >= 3, !grid.isEmpty else {
            return SpatialMap(metricName: metricName, samples: samples, warning: interpolate ? "At least three valid measured positions are required; interpolation was disabled." : nil)
        }
        let interpolated = grid.map { coordinate -> SpatialMapSample in
            let weighted = valid.compactMap { sample -> (Double, Double)? in guard let value = sample.metric else { return nil }; let d = max(coordinate.distance(to: sample.coordinate), 1e-9); return (1 / (d * d), value) }
            let weight = weighted.reduce(0) { $0 + $1.0 }; let value = weighted.reduce(0) { $0 + $1.0 * $1.1 } / max(weight, 1e-12)
            return SpatialMapSample(positionID: UUID(), coordinate: coordinate, metric: value, valid: true)
        }
        return SpatialMap(metricName: metricName, samples: samples, interpolated: interpolated, interpolationMethod: "inverse-distance weighting (power 2)", warning: "Interpolated values are estimates, not measurements.")
    }
}
