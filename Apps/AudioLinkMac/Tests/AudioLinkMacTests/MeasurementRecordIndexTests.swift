import Foundation
import Testing
@testable import AudioLinkMac

@Test func audioStatisticsProjectDelayJitterDriftAndConfidence() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let records = [
        MeasurementRecord(
            timestamp: now.addingTimeInterval(-2),
            audioPathName: "Loopback",
            excitationSignal: "Sine Sweep",
            latencyMs: 480,
            jitterMilliseconds: 0.4,
            clockDriftPPM: 2.0,
            correlationConfidence: 0.9,
            success: true,
            errorDescription: nil
        ),
        MeasurementRecord(
            timestamp: now.addingTimeInterval(-1),
            audioPathName: "Loopback",
            excitationSignal: "Sine Sweep",
            latencyMs: 500,
            jitterMilliseconds: 0.6,
            clockDriftPPM: 4.0,
            correlationConfidence: 0.8,
            success: true,
            errorDescription: nil
        )
    ]

    let summary = MeasurementRecordIndex(records: records).stats(for: ["Loopback"], now: now)
    #expect(summary.lastLatency == 500)
    #expect(summary.avgLatency24h == 490)
    #expect(abs((summary.jitterMilliseconds ?? 0) - 0.5) < 0.000_001)
    #expect(abs((summary.clockDriftPPM ?? 0) - 3) < 0.000_001)
    #expect(abs((summary.correlationConfidence ?? 0) - 0.85) < 0.000_001)
}

@Test func audioStatisticsDoNotInventMissingMetrics() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let failed = MeasurementRecord(
        timestamp: now,
        audioPathName: "System Audio Path",
        excitationSignal: "Impulse",
        latencyMs: nil,
        success: false,
        errorDescription: "Capture unavailable"
    )

    let summary = MeasurementRecordIndex(records: [failed]).stats(for: nil, now: now)
    #expect(summary.lastLatency == nil)
    #expect(summary.avgLatency24h == nil)
    #expect(summary.jitterMilliseconds == nil)
    #expect(summary.clockDriftPPM == nil)
    #expect(summary.correlationConfidence == nil)
}
