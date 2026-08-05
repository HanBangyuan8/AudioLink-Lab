import AudioLinkCore
import AudioLinkDSP
import AudioLinkNetworking
import AudioLinkRealtimeSupport
import Foundation

#if os(iOS)
import AVFoundation

/// iOS owns the route. This adapter reports the negotiated values instead of
/// pretending that arbitrary hardware sample rates or ports can be selected.
@MainActor
public final class MobileAudioSessionManager: NSObject, @unchecked Sendable {
    private let audioSession = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var accumulator: MobileCaptureAccumulator?
    private var tapInstalled = false
    private var engineStarted = false
    private var playerConnected = false
    private var currentRole: PeerRole = .recorder

    public private(set) var routeChangeCount = 0
    public private(set) var interruptionCount = 0
    public private(set) var lastRouteSnapshot: MobileRouteSnapshot?
    public private(set) var lastInterruptionReason: String?
    public private(set) var diagnostics = MobileAudioDiagnostics()
    public var onRouteChange: (() -> Void)?
    public var onInterruption: ((String) -> Void)?

    public var microphonePermission: MobileMicrophonePermission {
        switch audioSession.recordPermission {
        case .granted: .authorized
        case .denied: .denied
        case .undetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: audioSession)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: audioSession)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.routeChangeCount += 1
            self.lastRouteSnapshot = self.snapshot()
            self.onRouteChange?()
        }
    }

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.interruptionCount += 1
            self.lastInterruptionReason = rawType == AVAudioSession.InterruptionType.began.rawValue
                ? "An incoming call, Siri, or another audio session interrupted measurement."
                : "The audio interruption ended; the route must be checked before resuming."
            if rawType == AVAudioSession.InterruptionType.began.rawValue {
                self.stop()
                self.onInterruption?(self.lastInterruptionReason ?? "The iOS audio session was interrupted.")
            }
        }
    }

    public func requestMicrophoneAccess() async throws {
        switch audioSession.recordPermission {
        case .granted:
            return
        case .denied:
            throw MobileError.microphonePermissionDenied
        case .undetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw MobileError.microphonePermissionDenied }
        @unknown default:
            throw MobileError.microphonePermissionDenied
        }
    }

    public func configure(for role: PeerRole, preferredSampleRate: Double? = nil) throws -> MobileRouteSnapshot {
        currentRole = role
        let category: AVAudioSession.Category
        switch role {
        case .recorder: category = .record
        case .player: category = .playback
        case .controller, .responder: category = .playAndRecord
        }
        var options: AVAudioSession.CategoryOptions = []
        if role != .recorder { options.insert(.defaultToSpeaker) }
        options.insert(.allowBluetoothHFP)
        if role != .recorder { options.insert(.allowBluetoothA2DP) }
        do {
            try audioSession.setCategory(category, mode: .measurement, options: options)
            if let preferredSampleRate, preferredSampleRate.isFinite, preferredSampleRate > 0 {
                // This is a preference only. The subsequent snapshot is authoritative.
                try? audioSession.setPreferredSampleRate(preferredSampleRate)
            }
            try audioSession.setActive(true, options: [])
            let snapshot = self.snapshot()
            lastRouteSnapshot = snapshot
            return snapshot
        } catch {
            throw MobileError.audioSessionConfigurationFailed(error.localizedDescription)
        }
    }

    public func snapshot() -> MobileRouteSnapshot {
        let route = audioSession.currentRoute
        let input = route.inputs.first
        let output = route.outputs.first
        let inputType = input?.portType.rawValue
        let outputType = output?.portType.rawValue
        let bluetoothTypes: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        return MobileRouteSnapshot(
            inputName: input?.portName,
            outputName: output?.portName,
            inputPortType: inputType,
            outputPortType: outputType,
            sampleRateHertz: audioSession.sampleRate,
            inputChannelCount: input?.channels?.count ?? 0,
            outputChannelCount: output?.channels?.count ?? 0,
            ioBufferDurationSeconds: audioSession.ioBufferDuration,
            supportsBluetooth: input.map { bluetoothTypes.contains($0.portType) } ?? false
                || output.map { bluetoothTypes.contains($0.portType) } ?? false,
            isSpeakerOutput: output?.portType == .builtInSpeaker
        )
    }

    public func startRecording(maximumFrameCount: Int, bufferFrameCount: Int = 512) throws {
        guard currentRole == .recorder || currentRole == .controller || currentRole == .responder else {
            throw MobileError.unsupportedRole(currentRole)
        }
        guard audioSession.sampleRate > 0 else { throw MobileError.audioRouteUnavailable("The iOS route reports no sample rate.") }
        guard maximumFrameCount > 0, bufferFrameCount > 0 else { throw MobileError.audioSessionConfigurationFailed("The capture window is empty.") }
        stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        playerConnected = false
        engine.attach(player)
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MobileError.audioRouteUnavailable("The current route has no input channels.")
        }
        guard let newAccumulator = MobileCaptureAccumulator(maximumFrameCount: maximumFrameCount, selectedChannel: 0) else {
            throw MobileError.audioSessionConfigurationFailed("The bounded capture buffer could not be allocated.")
        }
        accumulator = newAccumulator
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(bufferFrameCount), format: format) { buffer, time in
            newAccumulator.append(buffer: buffer, time: time)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
            engineStarted = true
            let hostTime = DispatchTime.now().uptimeNanoseconds
            diagnostics = MobileAudioDiagnostics(
                engineStartHostTime: hostTime,
                recordingStartHostTime: hostTime,
                bufferFrameCount: bufferFrameCount,
                routeChangeCount: routeChangeCount,
                interruptionCount: interruptionCount
            )
        } catch {
            stop()
            throw MobileError.audioSessionConfigurationFailed("AVAudioEngine could not start: " + error.localizedDescription)
        }
    }

    public func play(signal: AudioSampleBuffer) throws -> UInt64 {
        guard currentRole == .player || currentRole == .controller || currentRole == .responder else {
            throw MobileError.unsupportedRole(currentRole)
        }
        let actualRate = audioSession.sampleRate
        guard abs(actualRate - signal.format.sampleRate.hertz) < 0.5 else {
            throw MobileError.audioRouteUnavailable(
                "The iOS route is " + String(actualRate) + " Hz, but the signal is " + String(signal.format.sampleRate.hertz) + " Hz."
            )
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: actualRate, channels: 1, interleaved: false),
              signal.frameCount <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(signal.frameCount)) else {
            throw MobileError.audioSessionConfigurationFailed("The test signal could not be converted to an iOS playback buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(signal.frameCount)
        guard let destination = buffer.floatChannelData?[0] else {
            throw MobileError.audioSessionConfigurationFailed("The playback buffer has no channel storage.")
        }
        try signal.withUnsafeChannelSamples(channel: 0) { source in
            guard let sourceAddress = source.baseAddress else { return }
            destination.update(from: sourceAddress, count: signal.frameCount)
        }
        if !engineStarted {
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playerConnected = true
            engine.prepare()
            do { try engine.start(); engineStarted = true }
            catch { throw MobileError.audioSessionConfigurationFailed("AVAudioEngine could not start playback: " + error.localizedDescription) }
        } else if !playerConnected {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playerConnected = true
        }
        let hostTime = DispatchTime.now().uptimeNanoseconds
        player.scheduleBuffer(buffer)
        player.play()
        diagnostics = MobileAudioDiagnostics(
            engineStartHostTime: diagnostics.engineStartHostTime ?? hostTime,
            recordingStartHostTime: diagnostics.recordingStartHostTime,
            playbackStartHostTime: hostTime,
            firstSampleTime: diagnostics.firstSampleTime,
            lastSampleTime: diagnostics.lastSampleTime,
            recordedFrameCount: diagnostics.recordedFrameCount,
            bufferFrameCount: diagnostics.bufferFrameCount,
            routeChangeCount: routeChangeCount,
            interruptionCount: interruptionCount,
            notes: diagnostics.notes
        )
        return hostTime
    }

    public func stopRecording() throws -> AudioSampleBuffer {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        engineStarted = false
        guard let accumulator else { throw MobileError.audioInterrupted("No iPhone recording is available.") }
        self.accumulator = nil
        let rate = audioSession.sampleRate
        let result = try accumulator.finish(sampleRate: rate)
        let timing = accumulator.timingSnapshot()
        diagnostics = MobileAudioDiagnostics(
            engineStartHostTime: diagnostics.engineStartHostTime,
            recordingStartHostTime: diagnostics.recordingStartHostTime,
            playbackStartHostTime: diagnostics.playbackStartHostTime,
            firstSampleTime: timing.firstSampleTime,
            lastSampleTime: timing.lastSampleTime,
            recordedFrameCount: timing.frameCount,
            bufferFrameCount: diagnostics.bufferFrameCount,
            routeChangeCount: routeChangeCount,
            interruptionCount: interruptionCount,
            notes: diagnostics.notes
        )
        return result
    }

    public func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        engine.reset()
        engineStarted = false
        playerConnected = false
        accumulator = nil
    }

    public func shutdown() {
        stop()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private final class MobileCaptureAccumulator: @unchecked Sendable {
    private let native: OpaquePointer
    private let selectedChannel: Int

    init?(maximumFrameCount: Int, selectedChannel: Int) {
        self.selectedChannel = selectedChannel
        guard let native = al_recording_accumulator_create(maximumFrameCount) else { return nil }
        self.native = native
    }

    func append(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channels = buffer.floatChannelData, selectedChannel < Int(buffer.format.channelCount) else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        al_recording_accumulator_append(
            native,
            channels[selectedChannel],
            count,
            time.isSampleTimeValid ? 1 : 0,
            time.isSampleTimeValid ? Double(time.sampleTime) : 0
        )
    }

    func finish(sampleRate: Double) throws -> AudioSampleBuffer {
        al_recording_accumulator_stop(native)
        let frameCount = al_recording_accumulator_count(native)
        var samples = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeMutableBufferPointer { destination in
            al_recording_accumulator_copy(native, destination.baseAddress, frameCount)
        }
        let rate = try SampleRate(hertz: sampleRate)
        return try AudioSampleBuffer(
            samples: samples,
            format: AudioFormatDescriptor(sampleRate: rate, channelCount: 1, bitDepth: 32, isInterleaved: false)
        )
    }

    func timingSnapshot() -> (firstSampleTime: Double?, lastSampleTime: Double?, frameCount: Int) {
        let hasFirst = al_recording_accumulator_has_first_sample_time(native) != 0
        let first = hasFirst ? al_recording_accumulator_first_sample_time(native) : nil
        let last = hasFirst ? al_recording_accumulator_last_sample_time(native) : nil
        return (first, last, al_recording_accumulator_count(native))
    }

    deinit {
        al_recording_accumulator_stop(native)
        al_recording_accumulator_destroy(native)
    }
}

#else

/// CI/macOS fallback. It keeps the iOS feature state testable without claiming
/// that AVAudioSession or iPhone routes exist on macOS.
@MainActor
public final class MobileAudioSessionManager: @unchecked Sendable {
    public private(set) var lastRouteSnapshot: MobileRouteSnapshot?
    public var diagnostics = MobileAudioDiagnostics()
    public var onRouteChange: (() -> Void)?
    public var onInterruption: ((String) -> Void)?
    public var microphonePermission: MobileMicrophonePermission { .unavailable }
    public init() {}
    public func requestMicrophoneAccess() async throws { throw MobileError.audioSessionConfigurationFailed("iOS audio sessions are unavailable on macOS.") }
    public func configure(for role: PeerRole, preferredSampleRate: Double? = nil) throws -> MobileRouteSnapshot {
        throw MobileError.audioSessionConfigurationFailed("Run AudioLinkMobile on an iPhone or iPad.")
    }
    public func snapshot() -> MobileRouteSnapshot {
        MobileRouteSnapshot(sampleRateHertz: 0, inputChannelCount: 0, outputChannelCount: 0, ioBufferDurationSeconds: 0, supportsBluetooth: false, isSpeakerOutput: false)
    }
    public func startRecording(maximumFrameCount: Int, bufferFrameCount: Int = 512) throws { throw MobileError.audioSessionConfigurationFailed("iOS audio sessions are unavailable on macOS.") }
    public func play(signal: AudioSampleBuffer) throws -> UInt64 { throw MobileError.audioSessionConfigurationFailed("iOS audio sessions are unavailable on macOS.") }
    public func stopRecording() throws -> AudioSampleBuffer { throw MobileError.audioInterrupted("No iOS recording is available.") }
    public func stop() {}
    public func shutdown() {}
}

#endif
