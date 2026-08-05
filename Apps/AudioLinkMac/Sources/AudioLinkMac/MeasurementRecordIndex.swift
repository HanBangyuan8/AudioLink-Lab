import Foundation

struct MeasurementRecordIndex {
    private(set) var allRecords: [MeasurementRecord]
    private var recordsByAudioPath: [String: [MeasurementRecord]]

    init(records: [MeasurementRecord]) {
        let sortedRecords = records.sorted { $0.timestamp < $1.timestamp }
        self.allRecords = sortedRecords
        self.recordsByAudioPath = Self.groupSortedRecords(sortedRecords)
    }

    mutating func replace(with records: [MeasurementRecord]) {
        let sortedRecords = records.sorted { $0.timestamp < $1.timestamp }
        allRecords = sortedRecords
        recordsByAudioPath = Self.groupSortedRecords(sortedRecords)
    }

    mutating func appending(
        _ newRecords: [MeasurementRecord],
        to records: [MeasurementRecord],
        retentionDays: Int,
        now: Date = Date()
    ) -> [MeasurementRecord] {
        guard !newRecords.isEmpty else { return records }

        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60)
        var updatedRecords = records
        updatedRecords.reserveCapacity(records.count + newRecords.count)
        updatedRecords.append(contentsOf: newRecords)

        if !Self.isSortedByTimestamp(updatedRecords) {
            updatedRecords.sort { $0.timestamp < $1.timestamp }
        }

        let startIndex = Self.lowerBound(in: updatedRecords, cutoff: cutoff)
        if startIndex > 0 {
            updatedRecords.removeFirst(startIndex)
        }

        allRecords = updatedRecords
        appendToAudioPathIndex(newRecords, cutoff: cutoff)
        return updatedRecords
    }

    func stats(for audioPaths: [String]?, now: Date = Date()) -> StatsSummary {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        var latencySum = 0
        var latencyCount = 0
        var jitterSum = 0.0
        var jitterCount = 0
        var driftSum = 0.0
        var driftCount = 0
        var confidenceSum = 0.0
        var confidenceCount = 0
        var lastRecord: MeasurementRecord?

        for series in selectedSeries(for: audioPaths) {
            if let candidate = series.last {
                if let currentLastRecord = lastRecord {
                    if candidate.timestamp > currentLastRecord.timestamp {
                        lastRecord = candidate
                    }
                } else {
                    lastRecord = candidate
                }
            }

            let startIndex = Self.lowerBound(in: series, cutoff: cutoff)
            guard startIndex < series.count else { continue }

            for record in series[startIndex...] {
                if record.success {
                    if let latency = record.latencyMs {
                        latencySum += latency
                        latencyCount += 1
                    }
                }
                if let jitter = record.jitterMilliseconds {
                    jitterSum += jitter
                    jitterCount += 1
                }
                if let drift = record.clockDriftPPM {
                    driftSum += drift
                    driftCount += 1
                }
                if let confidence = record.correlationConfidence {
                    confidenceSum += confidence
                    confidenceCount += 1
                }
            }
        }

        let average = latencyCount == 0 ? nil : Double(latencySum) / Double(latencyCount)

        return StatsSummary(
            lastLatency: lastRecord?.latencyMs,
            avgLatency24h: average,
            jitterMilliseconds: jitterCount == 0 ? nil : jitterSum / Double(jitterCount),
            clockDriftPPM: driftCount == 0 ? nil : driftSum / Double(driftCount),
            correlationConfidence: confidenceCount == 0 ? nil : confidenceSum / Double(confidenceCount)
        )
    }

    func chartData(
        hours: Double,
        audioPaths: [String]?,
        maxTotalPoints: Int,
        minimumPointsPerSeries: Int
    ) -> [MeasurementRecord] {
        let cutoff = Date().addingTimeInterval(-(hours * 60 * 60))
        var filtered: [MeasurementRecord] = []
        filtered.reserveCapacity(min(maxTotalPoints * 2, allRecords.count))

        for series in selectedSeries(for: audioPaths) {
            let startIndex = Self.lowerBound(in: series, cutoff: cutoff)
            guard startIndex < series.count else { continue }
            filtered.append(contentsOf: series[startIndex...])
        }

        if let audioPaths, audioPaths.count > 1 {
            filtered = Self.recordsInCompleteBatches(filtered, audioPaths: audioPaths)
            return ChartDownsampler.reduceAlignedBatches(
                filtered,
                maxTotalPoints: maxTotalPoints,
                seriesCount: audioPaths.count
            )
        }

        return ChartDownsampler.reduce(
            filtered,
            maxTotalPoints: maxTotalPoints,
            minimumPointsPerSeries: minimumPointsPerSeries
        )
    }

    func recentRecords(for audioPath: String? = nil, limit: Int) -> [MeasurementRecord] {
        let source = audioPath.map { recordsByAudioPath[$0] ?? [] } ?? allRecords
        return Array(source.suffix(limit).reversed())
    }

    private func selectedSeries(for audioPaths: [String]?) -> [[MeasurementRecord]] {
        guard let audioPaths, !audioPaths.isEmpty else {
            return [allRecords]
        }

        var seen = Set<String>()
        return audioPaths.compactMap { audioPath in
            guard seen.insert(audioPath).inserted else { return nil }
            return recordsByAudioPath[audioPath]
        }
    }

    private mutating func appendToAudioPathIndex(_ newRecords: [MeasurementRecord], cutoff: Date) {
        for record in newRecords where record.timestamp >= cutoff {
            var series = recordsByAudioPath[record.audioPathName] ?? []
            let needsSorting = series.last.map { $0.timestamp > record.timestamp } ?? false
            series.append(record)
            if needsSorting {
                series.sort { $0.timestamp < $1.timestamp }
            }
            recordsByAudioPath[record.audioPathName] = series
        }

        for audioPathName in Array(recordsByAudioPath.keys) {
            guard var series = recordsByAudioPath[audioPathName] else { continue }
            let startIndex = Self.lowerBound(in: series, cutoff: cutoff)
            if startIndex >= series.count {
                recordsByAudioPath.removeValue(forKey: audioPathName)
            } else if startIndex > 0 {
                series.removeFirst(startIndex)
                recordsByAudioPath[audioPathName] = series
            }
        }
    }

    private static func lowerBound(in records: [MeasurementRecord], cutoff: Date) -> Int {
        var low = 0
        var high = records.count
        while low < high {
            let middle = (low + high) / 2
            if records[middle].timestamp < cutoff {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func recordsInCompleteBatches(_ records: [MeasurementRecord], audioPaths: [String]) -> [MeasurementRecord] {
        let requiredAudioPaths = Set(audioPaths)
        guard !requiredAudioPaths.isEmpty else { return records }

        let grouped = Dictionary(grouping: records, by: \.timestamp)
        return grouped.values
            .filter { batch in
                requiredAudioPaths.isSubset(of: Set(batch.map(\.audioPathName)))
            }
            .flatMap { $0 }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func groupSortedRecords(_ records: [MeasurementRecord]) -> [String: [MeasurementRecord]] {
        Dictionary(grouping: records, by: \.audioPathName)
    }

    private static func isSortedByTimestamp(_ records: [MeasurementRecord]) -> Bool {
        guard records.count > 1 else { return true }
        for index in 1..<records.count where records[index - 1].timestamp > records[index].timestamp {
            return false
        }
        return true
    }
}

struct MeasurementStatsCacheKey: Hashable {
    let audioPaths: [String]?
    let minuteBucket: Int
}

struct MeasurementChartCacheKey: Hashable {
    let hours: Double
    let audioPaths: [String]?
    let maxTotalPoints: Int
    let minimumPointsPerSeries: Int
    let minuteBucket: Int
}
