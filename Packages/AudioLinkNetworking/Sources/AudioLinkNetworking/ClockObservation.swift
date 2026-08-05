import Foundation

public struct ClockObservation: Codable, Equatable, Sendable {
    public let t1: UInt64
    public let t2: UInt64
    public let t3: UInt64
    public let t4: UInt64

    public init(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) throws {
        guard t1 <= t2, t2 <= t3, t3 <= t4 else {
            throw ProtocolError.malformedMessage("Clock timestamps must be monotonic.")
        }
        self.t1 = t1; self.t2 = t2; self.t3 = t3; self.t4 = t4
    }

    /// NTP-style round-trip duration, in nanoseconds. This includes peer processing time.
    public var roundTripTimeNanoseconds: UInt64 { t4 - t1 }

    /// Candidate local-clock offset (remote minus local), in nanoseconds.
    public var offsetNanoseconds: Int64 {
        let forward = Int64(t2) - Int64(t1)
        let reverse = Int64(t4) - Int64(t3)
        return (forward - reverse) / 2
    }
}

public struct ClockObservationSummary: Codable, Equatable, Sendable {
    public let observations: [ClockObservation]
    public let medianRoundTripNanoseconds: UInt64?
    public let medianOffsetNanoseconds: Int64?

    public init(observations: [ClockObservation]) {
        self.observations = observations
        let rtts = observations.map(\.roundTripTimeNanoseconds).sorted()
        let offsets = observations.map(\.offsetNanoseconds).sorted()
        self.medianRoundTripNanoseconds = Self.median(rtts)
        self.medianOffsetNanoseconds = Self.median(offsets)
    }

    private static func median<T: Comparable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }
}

public enum ClockObservationCalculator {
    public static func makeObservation(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) throws -> ClockObservation {
        try ClockObservation(t1: t1, t2: t2, t3: t3, t4: t4)
    }
}
