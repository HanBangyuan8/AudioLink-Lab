import Foundation

public struct RetryAttempt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let attemptIndex: Int
    public let reason: String
    public let changedParameters: [String: String]
    public let expectedImprovement: String
    public let actualImprovement: Double?
    public let improved: Bool?
    public init(id: UUID = UUID(), attemptIndex: Int, reason: String, changedParameters: [String: String], expectedImprovement: String, actualImprovement: Double? = nil, improved: Bool? = nil) {
        self.id = id; self.attemptIndex = attemptIndex; self.reason = reason; self.changedParameters = changedParameters; self.expectedImprovement = expectedImprovement; self.actualImprovement = actualImprovement; self.improved = improved
    }
}

public struct RetryController: Sendable {
    public let strategy: RetryStrategy
    public init(strategy: RetryStrategy) { self.strategy = strategy }
    public func nextAttempt(after attemptIndex: Int, previousConfidence: Double?, currentConfidence: Double? = nil) -> RetryAttempt? {
        guard attemptIndex >= 0, attemptIndex < strategy.maximumAttempts else { return nil }
        if strategy.stopWhenNoImprovement, let previousConfidence, let currentConfidence, currentConfidence <= previousConfidence { return nil }
        guard let adjustment = strategy.adjustments[safe: attemptIndex % max(strategy.adjustments.count, 1)] else { return nil }
        return RetryAttempt(attemptIndex: attemptIndex + 1, reason: "The previous result did not meet the configured confidence target.", changedParameters: ["adjustment": adjustment.rawValue], expectedImprovement: expectedText(for: adjustment))
    }
    private func expectedText(for adjustment: RetryAdjustment) -> String {
        switch adjustment { case .extendDuration: "More integration time should raise correlation SNR."; case .increaseRepetition: "Averaging repeated probes should reduce random noise."; case .lowerAmplitude: "Lower level should reduce clipping without hiding it."; case .raiseAmplitudeWithinLimit: "A conservative level increase should improve input RMS."; case .widenSearchRange: "A wider lag window should avoid an edge peak."; case .changeSeed: "A different deterministic seed should reduce repeated-peak ambiguity."; case .useAperiodicSignal: "An aperiodic signal should separate similar paths."; case .extendPostRoll: "More tail capture should retain late arrivals."; case .requestHardwareGain: "The user may need to adjust hardware gain manually." }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
