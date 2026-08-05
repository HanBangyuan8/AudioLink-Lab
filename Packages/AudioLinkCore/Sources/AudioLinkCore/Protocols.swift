import Foundation

public protocol MeasurementPerforming: Sendable {
    func measure(configuration: MeasurementConfiguration) async throws -> MeasurementRun
}

