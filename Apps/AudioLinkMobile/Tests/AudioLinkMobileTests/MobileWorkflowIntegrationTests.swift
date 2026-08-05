import AudioLinkCore
import AudioLinkDSP
import AudioLinkNetworking
import Foundation
import Testing
@testable import AudioLinkMobile

@MainActor
struct MobileWorkflowIntegrationTests {
    @Test(.timeLimit(.minutes(1)))
    func controllerPairsWithSimulatedResponderOnlyAfterExplicitCodeConfirmation() async throws {
        let (left, right) = await InMemoryPeerTransport.pair()
        let localIdentity = PeerIdentity(displayName: "iPhone", roles: [.controller, .recorder])
        let remoteIdentity = PeerIdentity(displayName: "Mac", roles: [.controller, .player])
        let controller = MobileSessionController(
            localIdentity: localIdentity,
            discovery: InMemoryPeerDiscoveryService(),
            audio: MockMobileAudioDriver()
        )
        let peer = DiscoveredPeer(identity: remoteIdentity, endpointDescription: "loopback")
        let remote = SessionCoordinator(
            localIdentity: remoteIdentity,
            connection: PeerConnection(transport: right)
        )
        await controller.attach(connection: PeerConnection(transport: left), peer: peer)
        _ = try await remote.receiveAndHandle()
        _ = try await remote.receiveAndHandle()
        controller.pairingCodeText = "246810"
        await controller.requestPairing()
        #expect(try await remote.receiveAndHandle() == .pairingRequested)
        try await remote.acceptPairing(code: PairingCode("246810"))
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(controller.state == .paired)
        await controller.cancelMeasurement()
    }

    @Test func permissionFailureIsStructuredAndDoesNotPretendToRecord() async throws {
        let audio = MockMobileAudioDriver(permissionGranted: false)
        do {
            try await audio.requestMicrophoneAccess()
            Issue.record("Expected the mock permission denial")
        } catch let error as MobileError {
            #expect(error == .microphonePermissionDenied)
            #expect(!audio.didStartRecording)
        }
    }
}

@MainActor
private final class MockMobileAudioDriver: MobileAudioDriver {
    private let defaultRoute = MobileRouteSnapshot(
        sampleRateHertz: 48_000,
        inputChannelCount: 1,
        outputChannelCount: 1,
        ioBufferDurationSeconds: 0.01,
        supportsBluetooth: false,
        isSpeakerOutput: true
    )
    var lastRouteSnapshot: MobileRouteSnapshot?
    var microphonePermission: MobileMicrophonePermission { permissionGranted ? .authorized : .denied }
    var diagnostics = MobileAudioDiagnostics()
    var onRouteChange: (() -> Void)?
    var onInterruption: ((String) -> Void)?
    let permissionGranted: Bool
    private(set) var didStartRecording = false

    init(permissionGranted: Bool = true) {
        self.permissionGranted = permissionGranted
    }

    func requestMicrophoneAccess() async throws {
        guard permissionGranted else { throw MobileError.microphonePermissionDenied }
    }

    func configure(for role: PeerRole, preferredSampleRate: Double?) throws -> MobileRouteSnapshot {
        let route = MobileRouteSnapshot(
            sampleRateHertz: preferredSampleRate ?? defaultRoute.sampleRateHertz,
            inputChannelCount: defaultRoute.inputChannelCount,
            outputChannelCount: defaultRoute.outputChannelCount,
            ioBufferDurationSeconds: defaultRoute.ioBufferDurationSeconds,
            supportsBluetooth: defaultRoute.supportsBluetooth,
            isSpeakerOutput: defaultRoute.isSpeakerOutput
        )
        lastRouteSnapshot = route
        return route
    }

    func snapshot() -> MobileRouteSnapshot { lastRouteSnapshot ?? defaultRoute }
    func startRecording(maximumFrameCount: Int, bufferFrameCount: Int) throws { didStartRecording = true }
    func play(signal: AudioSampleBuffer) throws -> UInt64 { 1 }
    func stopRecording() throws -> AudioSampleBuffer {
        let rate = try SampleRate(hertz: 48_000)
        return try AudioSampleBuffer(
            samples: [0],
            format: AudioFormatDescriptor(sampleRate: rate, channelCount: 1, bitDepth: 32, isInterleaved: false)
        )
    }
    func stop() { didStartRecording = false }
    func shutdown() { didStartRecording = false }
}
