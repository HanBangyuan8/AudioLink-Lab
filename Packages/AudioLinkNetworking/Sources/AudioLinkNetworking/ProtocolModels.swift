import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The wire protocol is deliberately independent of SwiftUI and of the audio DSP packages.
public enum ProtocolVersion: String, Codable, CaseIterable, Comparable, Sendable {
    case v1 = "1.0"

    public static let current: ProtocolVersion = .v1

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        lhs.rawValue.compare(rhs.rawValue, options: .numeric) == .orderedAscending
    }

    public var isCompatibleWithCurrent: Bool { self == .current }
}

public enum PeerRole: String, Codable, CaseIterable, Hashable, Sendable {
    case controller
    case responder
    case recorder
    case player
}

public struct PeerCapabilities: Codable, Equatable, Sendable {
    public let roles: Set<PeerRole>
    public let supportsFileTransfer: Bool
    public let supportsClockObservation: Bool
    public let maxMessageBytes: Int
    public let maxFileBytes: Int64
    public let sampleRatesHertz: [Double]

    public init(
        roles: Set<PeerRole>,
        supportsFileTransfer: Bool = true,
        supportsClockObservation: Bool = true,
        maxMessageBytes: Int = ProtocolLimits.default.maxMessageBytes,
        maxFileBytes: Int64 = ProtocolLimits.default.maxFileBytes,
        sampleRatesHertz: [Double] = [44_100, 48_000, 96_000]
    ) {
        self.roles = roles
        self.supportsFileTransfer = supportsFileTransfer
        self.supportsClockObservation = supportsClockObservation
        self.maxMessageBytes = maxMessageBytes
        self.maxFileBytes = maxFileBytes
        self.sampleRatesHertz = sampleRatesHertz
    }
}

public struct PeerIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let peerID: UUID
    public let displayName: String
    public let roles: Set<PeerRole>
    public let protocolVersion: ProtocolVersion

    public init(
        peerID: UUID = UUID(),
        displayName: String,
        roles: Set<PeerRole>,
        protocolVersion: ProtocolVersion = .current
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.roles = roles
        self.protocolVersion = protocolVersion
    }

    public var id: UUID { peerID }
}

public struct ProtocolLimits: Codable, Equatable, Sendable {
    public static let `default` = ProtocolLimits(
        maxMessageBytes: 1_048_576,
        maxFileBytes: 2 * 1024 * 1024 * 1024,
        maxChunkBytes: 256 * 1024,
        maxChunkCount: 1_000_000
    )

    public let maxMessageBytes: Int
    public let maxFileBytes: Int64
    public let maxChunkBytes: Int
    public let maxChunkCount: Int

    public init(maxMessageBytes: Int, maxFileBytes: Int64, maxChunkBytes: Int, maxChunkCount: Int) {
        self.maxMessageBytes = maxMessageBytes
        self.maxFileBytes = maxFileBytes
        self.maxChunkBytes = maxChunkBytes
        self.maxChunkCount = maxChunkCount
    }
}

public enum ProtocolMessageKind: String, Codable, CaseIterable, Sendable {
    case hello
    case capabilityAdvertisement
    case pairingRequest
    case pairingResponse
    case sessionConfiguration
    case prepare
    case ready
    case start
    case stop
    case cancel
    case eventTimestamp
    case progress
    case resultSummary
    case error
    case heartbeat
    case fileTransferStart
    case fileChunk
    case fileTransferComplete
    case clockPing
    case clockPong
}

public struct HelloPayload: Codable, Equatable, Sendable {
    public let identity: PeerIdentity
    public let nonce: Data

    public init(identity: PeerIdentity, nonce: Data? = nil) {
        self.identity = identity
        self.nonce = nonce ?? Self.randomNonce()
    }

    private static func randomNonce() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }
}

public struct CapabilityAdvertisementPayload: Codable, Equatable, Sendable {
    public let capabilities: PeerCapabilities

    public init(capabilities: PeerCapabilities) { self.capabilities = capabilities }
}

public struct PairingRequestPayload: Codable, Equatable, Sendable {
    public let codeDigest: String
    public let requestedRoles: Set<PeerRole>

    public init(codeDigest: String, requestedRoles: Set<PeerRole>) {
        self.codeDigest = codeDigest
        self.requestedRoles = requestedRoles
    }
}

public struct PairingResponsePayload: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let reason: String?
    public let sessionToken: Data?

    public init(accepted: Bool, reason: String? = nil, sessionToken: Data? = nil) {
        self.accepted = accepted
        self.reason = reason
        self.sessionToken = sessionToken
    }
}

public struct SessionConfigurationPayload: Codable, Equatable, Sendable {
    public let sampleRateHertz: Double
    public let frameCount: Int64
    public let configuration: [String: String]

    public init(sampleRateHertz: Double, frameCount: Int64, configuration: [String: String] = [:]) {
        self.sampleRateHertz = sampleRateHertz
        self.frameCount = frameCount
        self.configuration = configuration
    }
}

public struct PreparePayload: Codable, Equatable, Sendable {
    public let runID: UUID
    public let roles: Set<PeerRole>
    public init(runID: UUID, roles: Set<PeerRole>) { self.runID = runID; self.roles = roles }
}

public struct ReadyPayload: Codable, Equatable, Sendable {
    public let runID: UUID
    public init(runID: UUID) { self.runID = runID }
}

public struct StartPayload: Codable, Equatable, Sendable {
    public let runID: UUID
    public let startToken: Data
    public let scheduledAfterNanoseconds: UInt64?
    public let localHostTimeNanoseconds: UInt64?
    public let preRollSamples: Int64?
    public let postRollSamples: Int64?
    public let sampleRateHertz: Double?

    public init(
        runID: UUID,
        startToken: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
        scheduledAfterNanoseconds: UInt64? = nil,
        localHostTimeNanoseconds: UInt64? = nil,
        preRollSamples: Int64? = nil,
        postRollSamples: Int64? = nil,
        sampleRateHertz: Double? = nil
    ) {
        self.runID = runID
        self.startToken = startToken
        self.scheduledAfterNanoseconds = scheduledAfterNanoseconds
        self.localHostTimeNanoseconds = localHostTimeNanoseconds
        self.preRollSamples = preRollSamples
        self.postRollSamples = postRollSamples
        self.sampleRateHertz = sampleRateHertz
    }
}

public struct RunControlPayload: Codable, Equatable, Sendable {
    public let runID: UUID
    public let reason: String?
    public init(runID: UUID, reason: String? = nil) { self.runID = runID; self.reason = reason }
}

public struct EventTimestampPayload: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let hostTimeNanoseconds: UInt64?
    public let sampleTime: Int64?
    public let sentAt: Date

    public init(eventID: UUID = UUID(), hostTimeNanoseconds: UInt64? = nil, sampleTime: Int64? = nil, sentAt: Date = Date()) {
        self.eventID = eventID
        self.hostTimeNanoseconds = hostTimeNanoseconds
        self.sampleTime = sampleTime
        self.sentAt = sentAt
    }
}

public struct ProgressPayload: Codable, Equatable, Sendable {
    public let fraction: Double
    public let message: String?
    public init(fraction: Double, message: String? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.message = message
    }
}

public struct ResultSummaryPayload: Codable, Equatable, Sendable {
    public let delaySamples: Double?
    public let delayMilliseconds: Double?
    public let quality: String?
    public let details: [String: String]
    public init(delaySamples: Double? = nil, delayMilliseconds: Double? = nil, quality: String? = nil, details: [String: String] = [:]) {
        self.delaySamples = delaySamples
        self.delayMilliseconds = delayMilliseconds
        self.quality = quality
        self.details = details
    }
}

public struct ErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let userMessage: String
    public let technicalDetails: String?
    public let retryable: Bool
    public init(code: String, userMessage: String, technicalDetails: String? = nil, retryable: Bool = false) {
        self.code = code
        self.userMessage = userMessage
        self.technicalDetails = technicalDetails
        self.retryable = retryable
    }
}

public struct HeartbeatPayload: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public init(sequence: UInt64) { self.sequence = sequence }
}

public struct FileTransferStartPayload: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let fileName: String
    public let fileSizeBytes: Int64
    public let sha256: String
    public let chunkSizeBytes: Int

    public init(transferID: UUID = UUID(), fileName: String, fileSizeBytes: Int64, sha256: String, chunkSizeBytes: Int) {
        self.transferID = transferID
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.sha256 = sha256
        self.chunkSizeBytes = chunkSizeBytes
    }
}

public struct FileChunkPayload: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let index: Int
    public let bytes: Data
    public init(transferID: UUID, index: Int, bytes: Data) { self.transferID = transferID; self.index = index; self.bytes = bytes }
}

public struct FileTransferCompletePayload: Codable, Equatable, Sendable {
    public let transferID: UUID
    public init(transferID: UUID) { self.transferID = transferID }
}

public struct ClockPingPayload: Codable, Equatable, Sendable {
    public let observationID: UUID
    public let t1: UInt64
    public init(observationID: UUID = UUID(), t1: UInt64) { self.observationID = observationID; self.t1 = t1 }
}

public struct ClockPongPayload: Codable, Equatable, Sendable {
    public let observationID: UUID
    public let t1: UInt64
    public let t2: UInt64
    public let t3: UInt64
    public init(observationID: UUID, t1: UInt64, t2: UInt64, t3: UInt64) {
        self.observationID = observationID; self.t1 = t1; self.t2 = t2; self.t3 = t3
    }
}

public struct ProtocolMessage: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let sessionID: UUID
    public let protocolVersion: ProtocolVersion
    public let sentAt: Date
    public let sequence: UInt64
    public let sessionToken: Data?
    public let kind: ProtocolMessageKind
    public let critical: Bool
    /// Payload is JSON encoded so adding a new payload does not change the envelope ABI.
    public let payload: Data

    public init(
        messageID: UUID = UUID(),
        sessionID: UUID,
        protocolVersion: ProtocolVersion = .current,
        sentAt: Date = Date(),
        sequence: UInt64,
        sessionToken: Data? = nil,
        kind: ProtocolMessageKind,
        critical: Bool = true,
        payload: Data
    ) {
        self.messageID = messageID
        self.sessionID = sessionID
        self.protocolVersion = protocolVersion
        self.sentAt = sentAt
        self.sequence = sequence
        self.sessionToken = sessionToken
        self.kind = kind
        self.critical = critical
        self.payload = payload
    }

    public init<P: Encodable>(
        sessionID: UUID,
        sequence: UInt64,
        kind: ProtocolMessageKind,
        payload: P,
        sessionToken: Data? = nil,
        critical: Bool = true,
        encoder: JSONEncoder = ProtocolCodec.encoder()
    ) throws {
        self.init(
            sessionID: sessionID,
            sequence: sequence,
            sessionToken: sessionToken,
            kind: kind,
            critical: critical,
            payload: try encoder.encode(payload)
        )
    }

    public func decodePayload<P: Decodable>(_ type: P.Type, decoder: JSONDecoder = ProtocolCodec.decoder()) throws -> P {
        try decoder.decode(P.self, from: payload)
    }
}

public enum ProtocolError: Error, LocalizedError, Equatable, Sendable {
    case messageTooLarge(limit: Int)
    case malformedMessage(String)
    case unknownMessage(String)
    case unknownCriticalMessage(String)
    case unsupportedVersion(ProtocolVersion)
    case unsupportedProtocolVersion(String)
    case sessionMismatch
    case replayedMessage
    case notPaired
    case pairingRejected(String)
    case timeout(String)
    case heartbeatLost
    case invalidState(String)
    case fileTooLarge(limit: Int64)
    case invalidFileName
    case checksumMismatch(expected: String, actual: String)
    case transferInterrupted
    case cancellation

    public var errorDescription: String? {
        switch self {
        case let .messageTooLarge(limit): return "The network message exceeds the " + String(limit) + "-byte safety limit."
        case let .malformedMessage(details): return "The peer sent a malformed message. " + details
        case let .unknownMessage(kind): return "The peer sent an unsupported message type: " + kind + "."
        case let .unknownCriticalMessage(kind): return "The peer requires an unsupported critical message: " + kind + "."
        case let .unsupportedVersion(version): return "The peer uses unsupported protocol version " + version.rawValue + "."
        case let .unsupportedProtocolVersion(version): return "The peer uses unsupported protocol version " + version + "."
        case .sessionMismatch: return "The message belongs to another measurement session."
        case .replayedMessage: return "The message was already received or is older than the replay window."
        case .notPaired: return "The peer has not been explicitly paired."
        case let .pairingRejected(reason): return "Pairing was rejected. " + reason
        case let .timeout(what): return "Timed out while waiting for " + what + "."
        case .heartbeatLost: return "The peer heartbeat was lost."
        case let .invalidState(details): return "The network session is not ready. " + details
        case let .fileTooLarge(limit): return "The file exceeds the " + String(limit) + "-byte transfer limit."
        case .invalidFileName: return "The peer supplied an invalid file name."
        case let .checksumMismatch(expected, actual): return "The transferred file checksum did not match (expected " + expected + ", received " + actual + ")."
        case .transferInterrupted: return "The file transfer was interrupted before completion."
        case .cancellation: return "The network operation was cancelled."
        }
    }
}

public enum ProtocolCodec {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ message: ProtocolMessage, limits: ProtocolLimits = .default) throws -> Data {
        let data = try encoder().encode(message)
        guard data.count <= limits.maxMessageBytes else { throw ProtocolError.messageTooLarge(limit: limits.maxMessageBytes) }
        return data
    }

    /// Unknown optional messages are ignored (`nil`); unknown critical messages are rejected.
    public static func decode(_ data: Data, limits: ProtocolLimits = .default) throws -> ProtocolMessage? {
        guard data.count <= limits.maxMessageBytes else { throw ProtocolError.messageTooLarge(limit: limits.maxMessageBytes) }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let kind = object["kind"] as? String,
           ProtocolMessageKind(rawValue: kind) == nil {
            let critical = object["critical"] as? Bool ?? true
            if critical { throw ProtocolError.unknownCriticalMessage(kind) }
            return nil
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["protocolVersion"] as? String,
           ProtocolVersion(rawValue: version) == nil {
            throw ProtocolError.unsupportedProtocolVersion(version)
        }
        do {
            let message = try decoder().decode(ProtocolMessage.self, from: data)
            guard message.protocolVersion.isCompatibleWithCurrent else {
                throw ProtocolError.unsupportedVersion(message.protocolVersion)
            }
            return message
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.malformedMessage(error.localizedDescription)
        }
    }
}

/// Stable facade for callers that do not need to know the JSON envelope implementation.
public enum MeasurementProtocol {
    public static let version = ProtocolVersion.current
    public static let limits = ProtocolLimits.default

    public static func encode(_ message: ProtocolMessage) throws -> Data {
        try ProtocolCodec.encode(message, limits: limits)
    }

    public static func decode(_ data: Data) throws -> ProtocolMessage? {
        try ProtocolCodec.decode(data, limits: limits)
    }
}

public struct PairingCode: Equatable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let normalized = value.filter(\.isNumber)
        guard normalized.count == 6 else { throw ProtocolError.pairingRejected("Pairing code must contain six digits.") }
        self.value = normalized
    }

    public static func generate() -> PairingCode {
        // Six digits are intentionally displayed to the user; the digest is sent over the wire.
        let raw = String(format: "%06d", Int.random(in: 0...999_999))
        // `raw` is constructed from exactly six decimal digits, so this initializer is total.
        return PairingCode(uncheckedSixDigitValue: raw)
    }

    private init(uncheckedSixDigitValue value: String) { self.value = value }

    public var digest: String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        // Apple platforms ship CryptoKit. The fallback only keeps non-Apple compilation
        // possible; it is not a cryptographic identity mechanism.
        let bytes = Array(value.utf8)
        let hash = bytes.reduce(into: UInt64(0xcbf29ce484222325)) { state, byte in
            state ^= UInt64(byte)
            state = state &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
        #endif
    }
}
