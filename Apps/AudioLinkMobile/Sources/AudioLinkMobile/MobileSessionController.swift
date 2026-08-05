import AudioLinkCore
import AudioLinkDSP
import AudioLinkNetworking
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
public protocol MobileAudioDriver: AnyObject {
    var lastRouteSnapshot: MobileRouteSnapshot? { get }
    var microphonePermission: MobileMicrophonePermission { get }
    var diagnostics: MobileAudioDiagnostics { get }
    func requestMicrophoneAccess() async throws
    func configure(for role: PeerRole, preferredSampleRate: Double?) throws -> MobileRouteSnapshot
    func snapshot() -> MobileRouteSnapshot
    func startRecording(maximumFrameCount: Int, bufferFrameCount: Int) throws
    func play(signal: AudioSampleBuffer) throws -> UInt64
    func stopRecording() throws -> AudioSampleBuffer
    func stop()
    func shutdown()
}

extension MobileAudioSessionManager: MobileAudioDriver {}

@MainActor
public final class MobileSessionController: ObservableObject {
    @Published public private(set) var state: MobileMeasurementState = .idle
    @Published public private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published public private(set) var selectedPeer: DiscoveredPeer?
    @Published public private(set) var routeSnapshot: MobileRouteSnapshot?
    @Published public private(set) var microphonePermission: MobileMicrophonePermission
    @Published public private(set) var networkDiagnostics = MobileNetworkDiagnostics()
    @Published public private(set) var audioDiagnostics = MobileAudioDiagnostics()
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var lastError: MobileError?
    @Published public var pairingCodeText = ""
    @Published public var localRole: PeerRole = .recorder
    @Published public var remoteRole: PeerRole = .player
    @Published public var retainRecording = false

    public let localIdentity: PeerIdentity
    public let audio: any MobileAudioDriver

    private let discovery: any PeerDiscoveryService
    private var discoveryTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var coordinator: SessionCoordinator?
    private var activePlan: MobileStartPlan?
    private var generatedSignal: GeneratedSignal?
    private var receivedRecordingURL: URL?
    private var finishedRunIDs: Set<UUID> = []
    private let recordingDirectory: URL
    private let signalGenerator = TestSignalGenerator()

    public convenience init() {
        let identity = MobileIdentityFactory.make()
        self.init(
            localIdentity: identity,
            discovery: BonjourPeerDiscoveryService(identity: identity),
            audio: MobileAudioSessionManager()
        )
    }

    public init(
        localIdentity: PeerIdentity,
        discovery: any PeerDiscoveryService,
        audio: any MobileAudioDriver,
        recordingDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("AudioLinkMobileRecordings", isDirectory: true)
    ) {
        self.localIdentity = localIdentity
        self.discovery = discovery
        self.audio = audio
        self.recordingDirectory = recordingDirectory
        self.microphonePermission = audio.microphonePermission
        self.audioDiagnostics = audio.diagnostics
        if let sessionManager = audio as? MobileAudioSessionManager {
            sessionManager.onRouteChange = { [weak self] in self?.handleAudioRouteChange() }
            sessionManager.onInterruption = { [weak self] reason in self?.handleAudioInterruption(reason) }
        }
    }

    deinit {
        discoveryTask?.cancel()
        receiveTask?.cancel()
        stopTask?.cancel()
    }

    public var statusText: String { state.label }
    public var isBusy: Bool { state.isActive }
    public var networkQualityText: String {
        guard let rtt = networkDiagnostics.lastRoundTripNanoseconds else { return "Not measured" }
        return String(format: "%.1f ms RTT", Double(rtt) / 1_000_000)
    }

    public func startDiscovery() {
        guard discoveryTask == nil else { return }
        state = .discovering
        lastError = nil
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.discovery.events()
            do {
                try await self.discovery.start()
            } catch {
                self.fail(.localNetworkPermissionRequired)
                return
            }
            for await event in stream {
                guard !Task.isCancelled else { return }
                self.handleDiscoveryEvent(event)
            }
        }
    }

    public func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        Task { await discovery.stop() }
        if !state.isActive { state = .idle }
    }

    public func connect(to peer: DiscoveredPeer) async {
        guard let provider = discovery as? any PeerConnectionProviding else {
            fail(.protocolFailure("This discovery provider does not create connections."))
            return
        }
        do {
            let connection = try await provider.connect(to: peer, timeoutNanoseconds: 10_000_000_000)
            await attach(connection: connection, peer: peer)
        } catch let error as ProtocolError {
            fail(.protocolFailure(error.localizedDescription))
        } catch {
            fail(.protocolFailure(error.localizedDescription))
        }
    }

    /// Test and simulated-peer entry point. Production discovery uses `connect(to:)`.
    public func attach(connection: PeerConnection, peer: DiscoveredPeer) async {
        receiveTask?.cancel()
        selectedPeer = peer
        state = .pairing(peer.identity)
        let session = SessionCoordinator(
            localIdentity: localIdentity,
            connection: connection,
            capabilities: PeerCapabilities(roles: localIdentity.roles)
        )
        coordinator = session
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await session.beginHandshake()
                while let event = try await session.receiveAndHandle() {
                    await self.handle(event)
                }
            } catch is CancellationError {
                return
            } catch let error as ProtocolError {
                self.fail(.protocolFailure(error.localizedDescription))
            } catch {
                self.fail(.protocolFailure(error.localizedDescription))
            }
        }
    }

    public func confirmPairing() async {
        do {
            let code = try PairingCode(pairingCodeText)
            guard let coordinator else { throw ProtocolError.invalidState("No peer connection is active.") }
            try await coordinator.acceptPairing(code: code)
            state = .paired
        } catch let error as MobileError {
            fail(error)
        } catch {
            fail(.protocolFailure(error.localizedDescription))
        }
    }

    public func requestPairing() async {
        do {
            let code = try PairingCode(pairingCodeText)
            guard let coordinator else { throw ProtocolError.invalidState("No peer connection is active.") }
            try await coordinator.requestPairing(with: code)
            state = .paired
        } catch {
            fail(.protocolFailure(error.localizedDescription))
        }
    }

    /// The controller sends a deterministic plan. The peer creates the same
    /// reference signal from the plan and the Mac remains responsible for the
    /// final correlation result.
    public func beginMeasurement() async {
        guard let coordinator else {
            fail(.protocolFailure("Pair with a device before starting a measurement."))
            return
        }
        guard case .paired = state else {
            fail(.protocolFailure("The paired session is not ready for a new measurement."))
            return
        }
        do {
            let requestedRate = routeSnapshot?.sampleRateHertz ?? 48_000
            routeSnapshot = try audio.configure(for: localRole, preferredSampleRate: requestedRate)
            microphonePermission = audio.microphonePermission
            let actualRate = routeSnapshot?.sampleRateHertz ?? requestedRate
            let rate = try SampleRate(hertz: actualRate > 0 ? actualRate : requestedRate)
            if let remoteCapabilities = await coordinator.remoteCapabilities {
                guard remoteCapabilities.roles.contains(remoteRole) else {
                    throw MobileError.unsupportedRole(remoteRole)
                }
                guard remoteCapabilities.sampleRatesHertz.contains(where: { abs($0 - rate.hertz) < 0.5 }) else {
                    throw MobileError.audioRouteUnavailable("The iPhone route sample rate is not supported by the paired Mac.")
                }
            }
            let plan = MobileStartPlan(
                role: remoteRole,
                signal: .logarithmicSweep,
                sampleRateHertz: rate.hertz,
                retainRecording: retainRecording
            )
            activePlan = plan
            generatedSignal = try makeSignal(for: plan)
            let planData = try JSONEncoder().encode(plan)
            let configuration = SessionConfigurationPayload(
                sampleRateHertz: rate.hertz,
                frameCount: Int64(generatedSignal?.audio.frameCount ?? 0),
                configuration: ["mobilePlan": planData.base64EncodedString()]
            )
            state = .preparing
            try await coordinator.sendSessionConfiguration(configuration)
            try await coordinator.sendPrepare(runID: plan.runID, roles: [localRole, remoteRole, .controller])
        } catch is CancellationError {
            fail(.cancelled)
        } catch {
            fail(.protocolFailure(error.localizedDescription))
        }
    }

    public func cancelMeasurement() async {
        stopTask?.cancel()
        stopTask = nil
        audio.stop()
        if let coordinator, let plan = activePlan {
            try? await coordinator.sendCancel(runID: plan.runID, reason: "Cancelled on mobile device")
        }
        state = .cancelled
        lastError = .cancelled
    }

    public func refreshRoute() {
        routeSnapshot = audio.snapshot()
        microphonePermission = audio.microphonePermission
    }

    public func shutdown() async {
        await cancelMeasurement()
        audio.shutdown()
        await coordinator?.close()
        coordinator = nil
    }

    private func handleDiscoveryEvent(_ event: DiscoveryEvent) {
        switch event {
        case .started:
            state = .discovering
        case let .peerFound(peer):
            if !discoveredPeers.contains(where: { $0.id == peer.id }) { discoveredPeers.append(peer) }
        case let .peerLost(identity):
            discoveredPeers.removeAll { $0.id == identity.peerID }
            if selectedPeer?.id == identity.peerID, state.isActive { fail(.protocolFailure("The selected Mac disappeared from the local network.")) }
        case let .failed(message):
            fail(message.localizedNetworkError)
        case .stopped:
            if !state.isActive { state = .idle }
        }
    }

    private func handle(_ event: SessionEvent) async {
        networkDiagnostics = MobileNetworkDiagnostics(
            lastRoundTripNanoseconds: networkDiagnostics.lastRoundTripNanoseconds,
            lastHeartbeatAt: networkDiagnostics.lastHeartbeatAt,
            reconnectCount: networkDiagnostics.reconnectCount,
            messagesReceived: networkDiagnostics.messagesReceived + 1,
            messagesSent: networkDiagnostics.messagesSent
        )
        switch event {
        case let .hello(identity):
            if let selectedPeer {
                self.selectedPeer = DiscoveredPeer(identity: identity, endpointDescription: selectedPeer.endpointDescription, discoveredAt: selectedPeer.discoveredAt)
            }
            state = .pairing(identity)
        case .capabilities:
            state = .pairing(selectedPeer?.identity ?? localIdentity)
        case .pairingRequested:
            state = .pairing(selectedPeer?.identity ?? localIdentity)
        case .pairingCompleted:
            state = .paired
        case let .sessionConfiguration(payload):
            await prepareRemotePlan(from: payload)
        case let .prepare(payload):
            if activePlan?.runID == nil { activePlan = MobileStartPlan(runID: payload.runID, role: remoteRole, sampleRateHertz: routeSnapshot?.sampleRateHertz ?? 48_000) }
            state = .preparing
            try? await coordinator?.sendReady(runID: payload.runID)
            state = .ready
        case .ready:
            state = .ready
            await startControllerRunIfNeeded()
        case let .start(payload):
            await startRemoteRun(payload)
        case let .stop(payload):
            await finishRun(runID: payload.runID)
        case .cancel:
            audio.stop()
            state = .cancelled
        case let .progress(value):
            progress = value.fraction
        case .heartbeat:
            networkDiagnostics = MobileNetworkDiagnostics(
                lastRoundTripNanoseconds: networkDiagnostics.lastRoundTripNanoseconds,
                lastHeartbeatAt: Date(),
                reconnectCount: networkDiagnostics.reconnectCount,
                messagesReceived: networkDiagnostics.messagesReceived,
                messagesSent: networkDiagnostics.messagesSent
            )
        case let .resultSummary(summary):
            state = .completed(MobileMeasurementSummary(
                runID: activePlan?.runID ?? UUID(),
                role: localRole,
                sampleRateHertz: activePlan?.sampleRateHertz ?? routeSnapshot?.sampleRateHertz ?? 0,
                rawDelaySamples: summary.delaySamples,
                rawDelayMilliseconds: summary.delayMilliseconds,
                quality: summary.quality,
                diagnostics: audioDiagnostics
            ))
        case let .remoteError(error):
            fail(.protocolFailure(error.userMessage))
        case .eventTimestamp, .clockPing, .clockPong, .fileTransferStarted, .fileChunk, .fileTransferCompleted, .ignoredUnknownMessage:
            break
        }
    }

    private func prepareRemotePlan(from payload: SessionConfigurationPayload) async {
        guard let encoded = payload.configuration["mobilePlan"],
              let data = Data(base64Encoded: encoded),
              let plan = try? JSONDecoder().decode(MobileStartPlan.self, from: data) else {
            fail(.protocolFailure("The Mac sent an invalid mobile measurement plan."))
            return
        }
        activePlan = plan
        do {
            generatedSignal = try makeSignal(for: plan)
            routeSnapshot = try audio.configure(for: plan.role, preferredSampleRate: plan.sampleRateHertz)
            if plan.role == .recorder { try await audio.requestMicrophoneAccess() }
            microphonePermission = audio.microphonePermission
            state = .preparing
        } catch let error as MobileError {
            fail(error)
            try? await coordinator?.sendError(ErrorPayload(code: "mobileAudio", userMessage: error.localizedDescription, retryable: true))
        } catch {
            fail(.audioSessionConfigurationFailed(error.localizedDescription))
        }
    }

    private func startControllerRunIfNeeded() async {
        guard let plan = activePlan, let coordinator else { return }
        do {
            try await prepareLocalAudio(for: localRole, plan: plan)
            try await coordinator.sendStart(
                runID: plan.runID,
                scheduledAfterNanoseconds: plan.scheduledAfterNanoseconds,
                localHostTimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                preRollSamples: Int64(plan.preRollSeconds * plan.sampleRateHertz),
                postRollSamples: Int64(plan.postRollSeconds * plan.sampleRateHertz),
                sampleRateHertz: plan.sampleRateHertz
            )
            if localRole == .player {
                try await Task.sleep(nanoseconds: plan.scheduledAfterNanoseconds)
                guard let generatedSignal else {
                    throw MobileError.audioSessionConfigurationFailed("The deterministic test signal is missing.")
                }
                _ = try audio.play(signal: generatedSignal.audio)
                audioDiagnostics = audio.diagnostics
            }
            state = .running
            scheduleStop(for: plan)
        } catch {
            fail(.audioSessionConfigurationFailed(error.localizedDescription))
        }
    }

    private func startRemoteRun(_ payload: StartPayload) async {
        guard let plan = activePlan else {
            fail(.protocolFailure("The peer sent start before a measurement plan."))
            return
        }
        do {
            try await prepareLocalAudio(for: plan.role, plan: plan)
            if plan.role == .player {
                try await Task.sleep(nanoseconds: payload.scheduledAfterNanoseconds ?? 0)
                guard let generatedSignal else { throw MobileError.audioSessionConfigurationFailed("The deterministic test signal is missing.") }
                _ = try audio.play(signal: generatedSignal.audio)
            }
            state = .running
        } catch is CancellationError {
            fail(.cancelled)
        } catch let error as MobileError {
            fail(error)
        } catch {
            fail(.audioSessionConfigurationFailed(error.localizedDescription))
        }
    }

    private func prepareLocalAudio(for role: PeerRole, plan: MobileStartPlan) async throws {
        routeSnapshot = try audio.configure(for: role, preferredSampleRate: plan.sampleRateHertz)
        microphonePermission = audio.microphonePermission
        if role == .recorder || role == .controller {
            try await audio.requestMicrophoneAccess()
            microphonePermission = audio.microphonePermission
        }
        if role == .recorder || role == .controller {
            let frames = Int(ceil((plan.preRollSeconds + plan.durationSeconds + plan.postRollSeconds) * plan.sampleRateHertz))
            try audio.startRecording(maximumFrameCount: max(frames, 1), bufferFrameCount: 512)
        }
        audioDiagnostics = audio.diagnostics
    }

    private func scheduleStop(for plan: MobileStartPlan) {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            do {
                let seconds = plan.preRollSeconds + plan.durationSeconds + plan.postRollSeconds + 0.1
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard let self, let coordinator = self.coordinator else { return }
                try await coordinator.sendStop(runID: plan.runID, reason: "Scheduled capture window completed")
                await self.finishRun(runID: plan.runID)
            } catch is CancellationError {
                return
            } catch {
                self?.fail(.protocolFailure(error.localizedDescription))
            }
        }
    }

    private func finishRun(runID: UUID) async {
        guard let coordinator else { return }
        guard !finishedRunIDs.contains(runID) else { return }
        finishedRunIDs.insert(runID)
        if localRole == .recorder {
            do {
                let captured = try audio.stopRecording()
                audioDiagnostics = audio.diagnostics
                try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
                let fileURL = recordingDirectory.appendingPathComponent("AudioLink-\(runID.uuidString).wav")
                let data = try WAVExporter().data(for: captured)
                try data.write(to: fileURL, options: [.atomic])
                state = .transferring
                if !retainRecording {
                    _ = try await coordinator.sendFile(at: fileURL, progress: { [weak self] value in
                        await self?.updateTransferProgress(value.fraction)
                    })
                    try? FileManager.default.removeItem(at: fileURL)
                }
                let summary = MobileMeasurementSummary(
                    runID: runID,
                    role: localRole,
                    sampleRateHertz: captured.format.sampleRate.hertz,
                    recordingFileName: retainRecording ? fileURL.lastPathComponent : nil,
                    diagnostics: audioDiagnostics.addingNote("Final acoustic analysis is performed by the Mac controller.")
                )
                state = .completed(summary)
                try? await coordinator.sendResultSummary(ResultSummaryPayload(quality: "pendingMacAnalysis", details: ["runID": runID.uuidString]))
            } catch {
                fail(.transferFailure(error.localizedDescription))
            }
        } else if localRole == .player && remoteRole == .recorder {
            do {
                audio.stop()
                audioDiagnostics = audio.diagnostics
                state = .transferring
                let result = try await coordinator.receiveFile(into: recordingDirectory, progress: { [weak self] value in
                    await self?.updateTransferProgress(value.fraction)
                })
                receivedRecordingURL = result.destinationURL
                state = .completed(MobileMeasurementSummary(
                    runID: runID,
                    role: localRole,
                    sampleRateHertz: routeSnapshot?.sampleRateHertz ?? 0,
                    recordingFileName: result.destinationURL.lastPathComponent,
                    diagnostics: audioDiagnostics.addingNote("The recording was received for final analysis on the controller Mac.")
                ))
            } catch is CancellationError {
                fail(.cancelled)
            } catch {
                fail(.transferFailure(error.localizedDescription))
            }
        } else {
            audio.stop()
            audioDiagnostics = audio.diagnostics
            state = .completed(MobileMeasurementSummary(runID: runID, role: localRole, sampleRateHertz: routeSnapshot?.sampleRateHertz ?? 0, diagnostics: audioDiagnostics))
        }
    }

    private func makeSignal(for plan: MobileStartPlan) throws -> GeneratedSignal {
        let rate = try SampleRate(hertz: plan.sampleRateHertz)
        let endFrequency = min(20_000, rate.hertz * 0.45)
        guard endFrequency > 20 else {
            throw MobileError.audioSessionConfigurationFailed("The negotiated iOS sample rate is too low for the reference sweep.")
        }
        return try signalGenerator.generate(configuration: TestSignalConfiguration(
            kind: plan.signal,
            sampleRate: rate,
            duration: try DurationSeconds(plan.durationSeconds),
            startFrequencyHertz: 20,
            endFrequencyHertz: endFrequency,
            amplitude: 0.18,
            preRollSilence: try DurationSeconds(plan.preRollSeconds),
            postRollSilence: try DurationSeconds(plan.postRollSeconds),
            fadeIn: .fiftyMilliseconds,
            fadeOut: .fiftyMilliseconds
        ))
    }

    private func updateTransferProgress(_ fraction: Double) {
        progress = min(max(fraction, 0), 1)
    }

    private func fail(_ error: MobileError) {
        lastError = error
        state = .failed(error)
        audio.stop()
    }

    private func handleAudioRouteChange() {
        routeSnapshot = audio.snapshot()
        microphonePermission = audio.microphonePermission
        guard state.isActive else { return }
        let error = MobileError.audioRouteUnavailable("The iOS route changed during measurement; recheck the route before starting again.")
        lastError = error
        state = .interrupted(error.localizedDescription)
        audio.stop()
    }

    private func handleAudioInterruption(_ reason: String) {
        guard state.isActive else { return }
        let error = MobileError.audioInterrupted(reason)
        lastError = error
        state = .interrupted(reason)
        audio.stop()
    }
}

@MainActor
public enum MobileIdentityFactory {
    public static func make() -> PeerIdentity {
#if os(iOS)
        let name = UIDevice.current.name.isEmpty ? "AudioLink iPhone" : UIDevice.current.name
#else
        let name = "AudioLink Mobile Simulator"
#endif
        return PeerIdentity(displayName: name, roles: [.controller, .recorder, .player])
    }
}

private extension String {
    var localizedNetworkError: MobileError { .protocolFailure(self) }
}
