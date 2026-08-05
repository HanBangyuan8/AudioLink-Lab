import Foundation

struct RecordRetentionPolicy {
    let retentionDays: Int

    func trim(_ records: [MeasurementRecord], now: Date = Date()) -> [MeasurementRecord] {
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60)
        return records.filter { $0.timestamp >= cutoff }
    }
}
