import Foundation

public enum RealtimePeerState: String, Codable, CaseIterable, Sendable {
    case idle
    case connecting
    case awaitingPairing
    case paired
    case preparing
    case ready
    case running
    case stopping
    case cancelling
    case reconnecting
    case failed
    case closed
}

public enum SessionEvent: Equatable, Sendable {
    case hello(PeerIdentity)
    case capabilities(PeerCapabilities)
    case pairingRequested
    case pairingCompleted
    case sessionConfiguration(SessionConfigurationPayload)
    case prepare(PreparePayload)
    case ready(ReadyPayload)
    case start(StartPayload)
    case stop(RunControlPayload)
    case cancel(RunControlPayload)
    case eventTimestamp(EventTimestampPayload)
    case progress(ProgressPayload)
    case resultSummary(ResultSummaryPayload)
    case remoteError(ErrorPayload)
    case heartbeat(HeartbeatPayload)
    case clockPing(ClockPingPayload)
    case clockPong(ClockPongPayload)
    case fileTransferStarted(FileTransferStartPayload)
    case fileChunk(FileChunkPayload)
    case fileTransferCompleted(FileTransferCompletePayload)
    case ignoredUnknownMessage
}

public actor ReplayGuard {
    private var seenIDs: Set<UUID> = []
    private var insertionOrder: [UUID] = []
    private var lastSequence: UInt64 = 0
    private let capacity: Int

    public init(capacity: Int = 4096) { self.capacity = max(16, capacity) }

    public func accept(_ message: ProtocolMessage) throws {
        guard !seenIDs.contains(message.messageID), message.sequence > lastSequence else {
            throw ProtocolError.replayedMessage
        }
        seenIDs.insert(message.messageID)
        insertionOrder.append(message.messageID)
        lastSequence = message.sequence
        if seenIDs.count > capacity {
            // Keep a bounded recent-ID window without clearing all IDs at once.
            // The monotonic sequence check remains the primary replay defense.
            let evicted = insertionOrder.removeFirst()
            seenIDs.remove(evicted)
        }
    }
}

public struct HeartbeatConfiguration: Codable, Equatable, Sendable {
    public let timeoutNanoseconds: UInt64
    public init(timeoutNanoseconds: UInt64 = 5_000_000_000) { self.timeoutNanoseconds = timeoutNanoseconds }
}

public actor SessionCoordinator {
    public let localIdentity: PeerIdentity
    public private(set) var sessionID: UUID
    public private(set) var state: RealtimePeerState = .idle
    public private(set) var remoteIdentity: PeerIdentity?
    public private(set) var remoteCapabilities: PeerCapabilities?
    public private(set) var sessionConfiguration: SessionConfigurationPayload?
    public private(set) var lastHeartbeatNanoseconds: UInt64?

    private var connection: PeerConnection
    private let localCapabilities: PeerCapabilities
    private let replayGuard = ReplayGuard()
    private let heartbeatConfiguration: HeartbeatConfiguration
    private var sequence: UInt64 = 0
    private var pairingCode: PairingCode?
    private var pendingPairingDigest: String?
    private var paired = false
    private var sessionToken: Data?
    private var activeRunID: UUID?

    public init(
        localIdentity: PeerIdentity,
        connection: PeerConnection,
        sessionID: UUID = UUID(),
        capabilities: PeerCapabilities? = nil,
        heartbeatConfiguration: HeartbeatConfiguration = .init()
    ) {
        self.localIdentity = localIdentity
        self.connection = connection
        self.sessionID = sessionID
        self.localCapabilities = capabilities ?? PeerCapabilities(roles: localIdentity.roles)
        self.heartbeatConfiguration = heartbeatConfiguration
    }

    public func beginHandshake(pairingCode: PairingCode? = nil) async throws {
        guard state == .idle || state == .reconnecting else { throw ProtocolError.invalidState("Handshake has already started.") }
        state = .connecting
        try await send(kind: .hello, payload: HelloPayload(identity: localIdentity), requiresPairing: false)
        try await send(kind: .capabilityAdvertisement, payload: CapabilityAdvertisementPayload(capabilities: localCapabilities), requiresPairing: false)
        if let pairingCode {
            self.pairingCode = pairingCode
            try await send(kind: .pairingRequest, payload: PairingRequestPayload(codeDigest: pairingCode.digest, requestedRoles: localIdentity.roles), requiresPairing: false)
        }
        state = .awaitingPairing
    }

    public func requestPairing(with code: PairingCode) async throws {
        guard state == .awaitingPairing || state == .connecting else { throw ProtocolError.invalidState("Pairing is not available yet.") }
        pairingCode = code
        try await send(kind: .pairingRequest, payload: PairingRequestPayload(codeDigest: code.digest, requestedRoles: localIdentity.roles), requiresPairing: false)
    }

    /// Called only after a human has compared the short code shown by both devices.
    public func acceptPairing(code: PairingCode) async throws {
        guard let pendingPairingDigest else { throw ProtocolError.invalidState("No pairing request is waiting.") }
        guard pendingPairingDigest == code.digest else { throw ProtocolError.pairingRejected("The verification code does not match.") }
        let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        sessionToken = token
        paired = true
        try await send(kind: .pairingResponse, payload: PairingResponsePayload(accepted: true, sessionToken: token), requiresPairing: false)
        state = .paired
    }

    public func rejectPairing(reason: String) async throws {
        guard pendingPairingDigest != nil else { throw ProtocolError.invalidState("No pairing request is waiting.") }
        try await send(kind: .pairingResponse, payload: PairingResponsePayload(accepted: false, reason: reason), requiresPairing: false)
        state = .failed
    }

    public func sendSessionConfiguration(_ configuration: SessionConfigurationPayload) async throws {
        try validate(configuration)
        try await send(kind: .sessionConfiguration, payload: configuration)
        sessionConfiguration = configuration
        state = .preparing
    }

    public func sendPrepare(runID: UUID, roles: Set<PeerRole>) async throws {
        try await send(kind: .prepare, payload: PreparePayload(runID: runID, roles: roles))
        activeRunID = runID
        state = .preparing
    }

    public func sendReady(runID: UUID) async throws {
        try validateRun(runID, allowedStates: [.preparing, .ready])
        try await send(kind: .ready, payload: ReadyPayload(runID: runID))
        state = .ready
    }

    public func sendStart(
        runID: UUID,
        startToken: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
        scheduledAfterNanoseconds: UInt64? = nil,
        localHostTimeNanoseconds: UInt64? = nil,
        preRollSamples: Int64? = nil,
        postRollSamples: Int64? = nil,
        sampleRateHertz: Double? = nil
    ) async throws {
        try validateRun(runID, allowedStates: [.ready])
        try validate(startToken: startToken, scheduledAfterNanoseconds: scheduledAfterNanoseconds, localHostTimeNanoseconds: localHostTimeNanoseconds, preRollSamples: preRollSamples, postRollSamples: postRollSamples, sampleRateHertz: sampleRateHertz)
        try await send(
            kind: .start,
            payload: StartPayload(
                runID: runID,
                startToken: startToken,
                scheduledAfterNanoseconds: scheduledAfterNanoseconds,
                localHostTimeNanoseconds: localHostTimeNanoseconds,
                preRollSamples: preRollSamples,
                postRollSamples: postRollSamples,
                sampleRateHertz: sampleRateHertz
            )
        )
        state = .running
    }

    public func sendStop(runID: UUID, reason: String? = nil) async throws {
        try validateRun(runID, allowedStates: [.running, .stopping])
        try await send(kind: .stop, payload: RunControlPayload(runID: runID, reason: reason))
        state = .stopping
    }

    public func sendCancel(runID: UUID, reason: String? = nil) async throws {
        try validateRun(runID, allowedStates: [.running, .stopping, .cancelling])
        try await send(kind: .cancel, payload: RunControlPayload(runID: runID, reason: reason))
        state = .cancelling
    }

    public func sendEventTimestamp(_ timestamp: EventTimestampPayload) async throws {
        try await send(kind: .eventTimestamp, payload: timestamp)
    }

    public func sendProgress(_ progress: ProgressPayload) async throws {
        try await send(kind: .progress, payload: progress)
    }

    public func sendResultSummary(_ summary: ResultSummaryPayload) async throws {
        try await send(kind: .resultSummary, payload: summary)
    }

    public func sendError(_ error: ErrorPayload) async throws {
        try await send(kind: .error, payload: error)
    }

    public func sendClockPing(t1: UInt64) async throws -> ClockPingPayload {
        let payload = ClockPingPayload(t1: t1)
        try await send(kind: .clockPing, payload: payload)
        return payload
    }

    public func sendClockPong(_ pong: ClockPongPayload) async throws {
        try await send(kind: .clockPong, payload: pong)
    }

    public func sendHeartbeat(nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) async throws {
        let value = HeartbeatPayload(sequence: sequence + 1)
        try await send(kind: .heartbeat, payload: value)
        lastHeartbeatNanoseconds = nowNanoseconds
    }

    public func checkHeartbeat(nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
        guard let lastHeartbeatNanoseconds else { throw ProtocolError.heartbeatLost }
        guard nowNanoseconds >= lastHeartbeatNanoseconds,
              nowNanoseconds - lastHeartbeatNanoseconds <= heartbeatConfiguration.timeoutNanoseconds else {
            throw ProtocolError.heartbeatLost
        }
    }

    public func markDisconnected() { state = .reconnecting }

    /// Reuses the session token only after the caller has revalidated the route.
    /// Pairing is required again when no token exists.
    public func reconnect(using transport: any PeerTransport) async throws {
        guard state == .reconnecting else { throw ProtocolError.invalidState("The session is not disconnected.") }
        connection = await connection.reconnect(with: transport)
        state = .connecting
        try await send(kind: .hello, payload: HelloPayload(identity: localIdentity), requiresPairing: false)
        try await send(kind: .capabilityAdvertisement, payload: CapabilityAdvertisementPayload(capabilities: localCapabilities), requiresPairing: false)
        state = paired ? .paired : .awaitingPairing
    }

    public func sendFile(
        at sourceURL: URL,
        using transferManager: TransferManager = TransferManager(),
        progress: (@Sendable (FileTransferProgress) async -> Void)? = nil
    ) async throws -> FileTransferResult {
        guard paired else { throw ProtocolError.notPaired }
        return try await transferManager.sendFile(
            at: sourceURL,
            over: connection,
            sessionID: sessionID,
            sessionToken: sessionToken,
            progress: progress
        )
    }

    public func receiveFile(
        into destinationDirectory: URL,
        using transferManager: TransferManager = TransferManager(),
        progress: (@Sendable (FileTransferProgress) async -> Void)? = nil
    ) async throws -> FileTransferResult {
        guard paired else { throw ProtocolError.notPaired }
        return try await transferManager.receiveFile(
            from: connection,
            destinationDirectory: destinationDirectory,
            sessionID: sessionID,
            sessionToken: sessionToken,
            progress: progress
        )
    }

    public func close() async {
        state = .closed
        await connection.close()
    }

    public func receiveAndHandle() async throws -> SessionEvent? {
        guard let message = try await connection.receive() else { return nil }
        if message.sessionID != sessionID {
            // The responder learns the controller's session identifier from the first hello.
            // Once pairing has started, changing it is never allowed.
            if remoteIdentity == nil && !paired && (state == .idle || state == .connecting || state == .awaitingPairing) {
                sessionID = message.sessionID
            } else {
                throw ProtocolError.sessionMismatch
            }
        }
        if paired {
            guard message.sessionToken == sessionToken else { throw ProtocolError.notPaired }
        }
        if let token = message.sessionToken, token.count > 64 {
            throw ProtocolError.malformedMessage("Session token exceeds the protocol safety limit.")
        }
        try await replayGuard.accept(message)
        return try await handle(message)
    }

    private func handle(_ message: ProtocolMessage) async throws -> SessionEvent? {
        switch message.kind {
        case .hello:
            let payload = try message.decodePayload(HelloPayload.self)
            remoteIdentity = payload.identity
            if state == .connecting { state = .awaitingPairing }
            return .hello(payload.identity)
        case .capabilityAdvertisement:
            let payload = try message.decodePayload(CapabilityAdvertisementPayload.self)
            remoteCapabilities = payload.capabilities
            return .capabilities(payload.capabilities)
        case .pairingRequest:
            let payload = try message.decodePayload(PairingRequestPayload.self)
            guard !payload.codeDigest.isEmpty, payload.codeDigest.count <= 128 else {
                throw ProtocolError.malformedMessage("Pairing verification digest has an invalid length.")
            }
            pendingPairingDigest = payload.codeDigest
            state = .awaitingPairing
            return .pairingRequested
        case .pairingResponse:
            let payload = try message.decodePayload(PairingResponsePayload.self)
            guard payload.accepted else {
                state = .failed
                throw ProtocolError.pairingRejected(payload.reason ?? "The other device rejected pairing.")
            }
            guard let token = payload.sessionToken, !token.isEmpty, token.count <= 64 else { throw ProtocolError.malformedMessage("Pairing response did not contain a valid session token.") }
            sessionToken = token
            paired = true
            state = .paired
            return .pairingCompleted
        case .sessionConfiguration:
            let payload = try message.decodePayload(SessionConfigurationPayload.self)
            try validate(payload)
            sessionConfiguration = payload
            state = .preparing
            return .sessionConfiguration(payload)
        case .prepare:
            let payload = try message.decodePayload(PreparePayload.self)
            if let activeRunID, activeRunID != payload.runID {
                throw ProtocolError.invalidState("A different measurement run is already active.")
            }
            activeRunID = payload.runID
            state = .preparing
            return .prepare(payload)
        case .ready:
            let payload = try message.decodePayload(ReadyPayload.self)
            try validateRun(payload.runID, allowedStates: [.preparing, .ready])
            state = .ready
            return .ready(payload)
        case .start:
            let payload = try message.decodePayload(StartPayload.self)
            try validateRun(payload.runID, allowedStates: [.ready])
            try validate(startToken: payload.startToken, scheduledAfterNanoseconds: payload.scheduledAfterNanoseconds, localHostTimeNanoseconds: payload.localHostTimeNanoseconds, preRollSamples: payload.preRollSamples, postRollSamples: payload.postRollSamples, sampleRateHertz: payload.sampleRateHertz)
            state = .running
            return .start(payload)
        case .stop:
            let payload = try message.decodePayload(RunControlPayload.self)
            try validateRun(payload.runID, allowedStates: [.running, .stopping])
            state = .stopping
            return .stop(payload)
        case .cancel:
            let payload = try message.decodePayload(RunControlPayload.self)
            try validateRun(payload.runID, allowedStates: [.running, .stopping, .cancelling])
            state = .cancelling
            return .cancel(payload)
        case .eventTimestamp:
            return .eventTimestamp(try message.decodePayload(EventTimestampPayload.self))
        case .progress:
            let payload = try message.decodePayload(ProgressPayload.self)
            guard payload.fraction.isFinite, (0...1).contains(payload.fraction) else {
                throw ProtocolError.malformedMessage("Progress fraction must be finite and within 0...1.")
            }
            return .progress(payload)
        case .resultSummary:
            let payload = try message.decodePayload(ResultSummaryPayload.self)
            let finite = [payload.delaySamples, payload.delayMilliseconds].compactMap { $0 }
            guard finite.allSatisfy(\.isFinite) else { throw ProtocolError.malformedMessage("Result values must be finite.") }
            return .resultSummary(payload)
        case .error:
            return .remoteError(try message.decodePayload(ErrorPayload.self))
        case .heartbeat:
            let payload = try message.decodePayload(HeartbeatPayload.self)
            lastHeartbeatNanoseconds = DispatchTime.now().uptimeNanoseconds
            return .heartbeat(payload)
        case .clockPing:
            return .clockPing(try message.decodePayload(ClockPingPayload.self))
        case .clockPong:
            return .clockPong(try message.decodePayload(ClockPongPayload.self))
        case .fileTransferStart:
            return .fileTransferStarted(try message.decodePayload(FileTransferStartPayload.self))
        case .fileChunk:
            return .fileChunk(try message.decodePayload(FileChunkPayload.self))
        case .fileTransferComplete:
            return .fileTransferCompleted(try message.decodePayload(FileTransferCompletePayload.self))
        }
    }

    private func send<P: Encodable>(kind: ProtocolMessageKind, payload: P, critical: Bool = true, requiresPairing: Bool = true) async throws {
        if requiresPairing && !paired { throw ProtocolError.notPaired }
        guard sequence < UInt64.max else { throw ProtocolError.invalidState("The session message sequence is exhausted.") }
        sequence += 1
        let message = try ProtocolMessage(
            sessionID: sessionID,
            sequence: sequence,
            kind: kind,
            payload: payload,
            sessionToken: requiresPairing ? sessionToken : nil,
            critical: critical
        )
        try await connection.send(message)
    }

    private func validate(_ configuration: SessionConfigurationPayload) throws {
        guard configuration.sampleRateHertz.isFinite, configuration.sampleRateHertz > 0,
              configuration.frameCount > 0 else {
            throw ProtocolError.malformedMessage("Session configuration contains an invalid sample rate or frame count.")
        }
    }

    private func validateRun(_ runID: UUID, allowedStates: [RealtimePeerState]) throws {
        guard activeRunID == runID else { throw ProtocolError.invalidState("The message does not belong to the active measurement run.") }
        guard allowedStates.contains(state) else { throw ProtocolError.invalidState("The message is not valid while the session is \(state.rawValue).") }
    }

    private func validate(
        startToken: Data,
        scheduledAfterNanoseconds: UInt64?,
        localHostTimeNanoseconds: UInt64?,
        preRollSamples: Int64?,
        postRollSamples: Int64?,
        sampleRateHertz: Double?
    ) throws {
        guard !startToken.isEmpty, startToken.count <= 256 else {
            throw ProtocolError.malformedMessage("Start token has an invalid length.")
        }
        _ = scheduledAfterNanoseconds
        _ = localHostTimeNanoseconds
        if let preRollSamples, preRollSamples < 0 { throw ProtocolError.malformedMessage("Pre-roll cannot be negative.") }
        if let postRollSamples, postRollSamples < 0 { throw ProtocolError.malformedMessage("Post-roll cannot be negative.") }
        if let sampleRateHertz, (!sampleRateHertz.isFinite || sampleRateHertz <= 0) { throw ProtocolError.malformedMessage("Sample rate must be finite and positive.") }
    }
}
