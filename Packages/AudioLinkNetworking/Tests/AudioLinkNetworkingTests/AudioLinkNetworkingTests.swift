import Foundation
import Testing
@testable import AudioLinkNetworking

@Suite("AudioLink networking foundation")
struct AudioLinkNetworkingTests {
    @Test func capabilitiesDescribeTheTransportMilestone() {
        let capabilities = AudioLinkNetworkingCapabilities.foundationMilestone
        #expect(capabilities.supportsDiscovery)
        #expect(capabilities.supportsClockSynchronization)
        #expect(!capabilities.supportsAudioTransport)
    }

    @Test func protocolRoundTripPreservesEnvelopeAndPayload() throws {
        let sessionID = UUID()
        let message = try ProtocolMessage(
            sessionID: sessionID,
            sequence: 7,
            kind: .progress,
            payload: ProgressPayload(fraction: 0.5, message: "halfway")
        )
        let wire = try ProtocolCodec.encode(message)
        let decodedValue = try ProtocolCodec.decode(wire)
        let decoded = try #require(decodedValue)
        #expect(decoded.messageID == message.messageID)
        #expect(decoded.sessionID == sessionID)
        #expect(decoded.sequence == 7)
        #expect(try decoded.decodePayload(ProgressPayload.self) == ProgressPayload(fraction: 0.5, message: "halfway"))
    }

    @Test func unknownNonCriticalMessageIsIgnoredAndCriticalMessageRejected() throws {
        let optional = Data(#"{"kind":"futureTelemetry","critical":false}"#.utf8)
        #expect(try ProtocolCodec.decode(optional) == nil)
        let critical = Data(#"{"kind":"futureCommand","critical":true}"#.utf8)
        do {
            _ = try ProtocolCodec.decode(critical)
            Issue.record("Expected an unknown critical message to be rejected")
        } catch let error as ProtocolError {
            #expect(error == .unknownCriticalMessage("futureCommand"))
        }
        do {
            _ = try ProtocolCodec.decode(Data(#"{"protocolVersion":"9.0"}"#.utf8))
            Issue.record("Expected a protocol version mismatch to be rejected")
        } catch let error as ProtocolError {
            #expect(error == .unsupportedProtocolVersion("9.0"))
        }
    }

    @Test func simulatedDiscoveryReportsFoundAndLostPeers() async throws {
        let discovery = InMemoryPeerDiscoveryService()
        let stream = await discovery.events()
        var iterator = stream.makeAsyncIterator()
        try await discovery.start()
        #expect(await iterator.next() == .started)
        let identity = PeerIdentity(displayName: "Recorder", roles: [.recorder])
        let peer = DiscoveredPeer(identity: identity, endpointDescription: "loopback")
        await discovery.add(peer)
        #expect(await iterator.next() == .peerFound(peer))
        await discovery.remove(peerID: identity.peerID)
        #expect(await iterator.next() == .peerLost(identity))
        await discovery.stop()
        #expect(await iterator.next() == .stopped)
    }

    @Test func closedLoopbackPeerRejectsFurtherWrites() async throws {
        let (left, right) = await InMemoryPeerTransport.pair()
        await right.close()
        do {
            try await left.send(Data([1]))
            Issue.record("Expected a closed peer write to fail")
        } catch let error as ProtocolError {
            #expect(error == .transferInterrupted)
        }
    }

    @Test func cancelledInMemoryReceiveRemovesItsContinuation() async throws {
        let (left, right) = await InMemoryPeerTransport.pair()
        let task = Task {
            try await left.receive()
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected the pending receive to observe cancellation")
        } catch is CancellationError {
            // Expected. A later send must not resume an orphaned continuation.
        }
        try await right.send(Data([7]))
        #expect(try await left.receive() == Data([7]))
    }

    @Test(.timeLimit(.minutes(1)))
    func twoSimulatedPeersPairExchangeConfigurationAndControl() async throws {
        let (leftTransport, rightTransport) = await InMemoryPeerTransport.pair()
        let sessionID = UUID()
        let controllerIdentity = PeerIdentity(displayName: "Controller", roles: [.controller])
        let controller = SessionCoordinator(
            localIdentity: controllerIdentity,
            connection: PeerConnection(transport: leftTransport),
            sessionID: sessionID
        )
        let responder = SessionCoordinator(
            localIdentity: PeerIdentity(displayName: "Recorder", roles: [.recorder]),
            connection: PeerConnection(transport: rightTransport),
            sessionID: sessionID
        )
        let code = try PairingCode("123456")
        try await controller.beginHandshake(pairingCode: code)
        #expect(try await responder.receiveAndHandle() == .hello(controllerIdentity))
        #expect(try await responder.receiveAndHandle() == .capabilities(PeerCapabilities(roles: [.controller])))
        #expect(try await responder.receiveAndHandle() == .pairingRequested)
        try await responder.acceptPairing(code: code)
        #expect(try await controller.receiveAndHandle() == .pairingCompleted)
        let configuration = SessionConfigurationPayload(sampleRateHertz: 48_000, frameCount: 96_000, configuration: ["signal": "logSweep"])
        try await controller.sendSessionConfiguration(configuration)
        #expect(try await responder.receiveAndHandle() == .sessionConfiguration(configuration))
        let runID = UUID()
        try await controller.sendPrepare(runID: runID, roles: [.controller, .recorder])
        #expect(try await responder.receiveAndHandle() == .prepare(PreparePayload(runID: runID, roles: [.controller, .recorder])))
        try await responder.sendReady(runID: runID)
        #expect(try await controller.receiveAndHandle() == .ready(ReadyPayload(runID: runID)))
        try await controller.sendStart(runID: runID, startToken: Data([1, 2, 3]))
        #expect(try await responder.receiveAndHandle() == .start(StartPayload(runID: runID, startToken: Data([1, 2, 3]))) )
        try await controller.sendStop(runID: runID)
        #expect(try await responder.receiveAndHandle() == .stop(RunControlPayload(runID: runID)))
    }

    @Test func replayGuardRejectsDuplicateAndOldMessages() async throws {
        let guardObject = ReplayGuard()
        let message = try ProtocolMessage(sessionID: UUID(), sequence: 1, kind: .heartbeat, payload: HeartbeatPayload(sequence: 1))
        try await guardObject.accept(message)
        do {
            try await guardObject.accept(message)
            Issue.record("Expected replay to be rejected")
        } catch let error as ProtocolError {
            #expect(error == .replayedMessage)
        }
        let old = try ProtocolMessage(sessionID: message.sessionID, sequence: 1, kind: .heartbeat, payload: HeartbeatPayload(sequence: 1))
        do {
            try await guardObject.accept(old)
            Issue.record("Expected an old sequence to be rejected")
        } catch let error as ProtocolError {
            #expect(error == .replayedMessage)
        }
    }

    @Test func clockObservationUsesFourTimestampFormula() throws {
        let observation = try ClockObservation(t1: 1_000, t2: 1_150, t3: 1_160, t4: 1_270)
        #expect(observation.roundTripTimeNanoseconds == 270)
        #expect(observation.offsetNanoseconds == 20)
        let summary = ClockObservationSummary(observations: [observation])
        #expect(summary.medianOffsetNanoseconds == 20)
    }

    @Test(.timeLimit(.minutes(1)))
    func fileTransferStreamsChunksAndVerifiesChecksum() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let sourceURL = sourceDirectory.appendingPathComponent("fixture.bin")
        let sourceData = Data((0..<200_000).map { UInt8($0 % 251) })
        try sourceData.write(to: sourceURL)
        let (leftTransport, rightTransport) = await InMemoryPeerTransport.pair()
        let senderConnection = PeerConnection(transport: leftTransport)
        let receiverConnection = PeerConnection(transport: rightTransport)
        let sender = TransferManager(limits: FileTransferLimits(ProtocolLimits(maxMessageBytes: 300_000, maxFileBytes: 1_000_000, maxChunkBytes: 16_384, maxChunkCount: 100)))
        let receiver = TransferManager(limits: FileTransferLimits(ProtocolLimits(maxMessageBytes: 300_000, maxFileBytes: 1_000_000, maxChunkBytes: 16_384, maxChunkCount: 100)))
        let sessionID = UUID()
        let receiverTask = Task {
            try await receiver.receiveFile(from: receiverConnection, destinationDirectory: destinationDirectory, sessionID: sessionID)
        }
        let sent = try await sender.sendFile(at: sourceURL, over: senderConnection, sessionID: sessionID)
        let received = try await receiverTask.value
        #expect(sent.bytesTransferred == sourceData.count)
        #expect(received.bytesTransferred == sourceData.count)
        #expect(try Data(contentsOf: received.destinationURL) == sourceData)
    }

    @Test func malformedAndOversizedDataIsRejected() throws {
        let limits = ProtocolLimits(maxMessageBytes: 32, maxFileBytes: 1_000, maxChunkBytes: 10, maxChunkCount: 2)
        do {
            _ = try ProtocolCodec.decode(Data(repeating: 0, count: 33), limits: limits)
            Issue.record("Expected oversized data to be rejected")
        } catch let error as ProtocolError {
            #expect(error == .messageTooLarge(limit: 32))
        }
        do {
            _ = try ProtocolCodec.decode(Data("not-json".utf8))
            Issue.record("Expected malformed data to be rejected")
        } catch let error as ProtocolError {
            if case .malformedMessage = error { } else { Issue.record("Expected malformedMessage, got \(error)") }
        }
    }
}
