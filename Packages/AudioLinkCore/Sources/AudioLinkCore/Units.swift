import Foundation

public enum UnitValidationError: Error, Codable, Equatable, Sendable {
    case nonFiniteValue(unit: String)
    case nonPositiveValue(unit: String, value: Double)
    case negativeValue(unit: String, value: Double)
}

public struct SampleCount: RawRepresentable, Codable, Equatable, Hashable, Comparable, Sendable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func duration(at sampleRate: SampleRate) -> DurationSeconds {
        DurationSeconds(validatedValue: Double(rawValue) / sampleRate.hertz)
    }
}

public struct SampleRate: Codable, Equatable, Hashable, Comparable, Sendable {
    public static let hz44100 = SampleRate(validatedValue: 44_100)
    public static let hz48000 = SampleRate(validatedValue: 48_000)
    public static let hz96000 = SampleRate(validatedValue: 96_000)

    public let hertz: Double

    public init(hertz: Double) throws {
        guard hertz.isFinite else {
            throw UnitValidationError.nonFiniteValue(unit: "hertz")
        }
        guard hertz > 0 else {
            throw UnitValidationError.nonPositiveValue(unit: "hertz", value: hertz)
        }
        self.hertz = hertz
    }

    private init(validatedValue: Double) {
        hertz = validatedValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.hertz < rhs.hertz
    }

    private enum CodingKeys: String, CodingKey { case hertz }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(hertz: container.decode(Double.self, forKey: .hertz))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hertz, forKey: .hertz)
    }
}

public struct DurationSeconds: Codable, Equatable, Hashable, Comparable, Sendable {
    public static let zero = DurationSeconds(validatedValue: 0)
    public static let fiftyMilliseconds = DurationSeconds(validatedValue: 0.05)
    public static let oneTenthSecond = DurationSeconds(validatedValue: 0.1)

    public let value: Double

    public init(_ value: Double) throws {
        guard value.isFinite else {
            throw UnitValidationError.nonFiniteValue(unit: "seconds")
        }
        guard value >= 0 else {
            throw UnitValidationError.negativeValue(unit: "seconds", value: value)
        }
        self.value = value
    }

    fileprivate init(validatedValue: Double) {
        value = validatedValue
    }

    public var milliseconds: Double { value * 1_000 }

    public func sampleCount(at sampleRate: SampleRate) -> SampleCount {
        SampleCount(rawValue: Int64((value * sampleRate.hertz).rounded()))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    private enum CodingKeys: String, CodingKey { case value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(Double.self, forKey: .value))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

public struct PartsPerMillion: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: Double

    public init(rawValue: Double) {
        self.rawValue = rawValue
    }
}
