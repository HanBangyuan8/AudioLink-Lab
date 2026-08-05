import AudioLinkCore
import AudioLinkDSP
import AudioLinkRealtimeSupport
import AudioToolbox
import AVFoundation
import Foundation

public actor AVAudioEngineRealtimeController: PlaybackController, RecordingController {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var preparedBuffer: AVAudioPCMBuffer?
    private var preparedRoute: AudioRouteConfiguration?
    private var accumulator: RecordingAccumulator?
    private var tapInstalled = false
    private var engineStarted = false
    private var playbackTiming: PlaybackTiming?
    private var recordingStartTiming: RecordingStart?

    public init() {}

    public func preparePlayback(
        signal: AudioSampleBuffer,
        route: AudioRouteConfiguration
    ) async throws {
        guard signal.format.sampleRate == route.sampleRate else {
            throw failure(
                .sampleRateMismatch,
                message: "The generated signal sample rate does not match the selected audio route.",
                recovery: "Regenerate the signal at the route sample rate.",
                context: "signal=\(signal.format.sampleRate.hertz), route=\(route.sampleRate.hertz)"
            )
        }
        await stopPlayback()
        await cancelRecording()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        try setDevice(route.outputDevice.objectID, on: engine.outputNode.audioUnit, role: "output")

        let buffer = try makePlaybackBuffer(signal: signal, route: route)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        preparedBuffer = buffer
        preparedRoute = route
        playbackTiming = nil
    }

    public func startRecording(
        route: AudioRouteConfiguration,
        maximumFrameCount: Int
    ) async throws -> RecordingStart {
        guard !engineStarted else {
            throw failure(
                .alreadyRunning,
                message: "The real-time audio engine is already running.",
                recovery: "Stop the current measurement before starting another.",
                context: nil
            )
        }
        guard preparedRoute == route, preparedBuffer != nil else {
            throw failure(
                .recordingFailed,
                message: "Playback was not prepared for the selected route.",
                recovery: "Prepare the test signal again.",
                context: nil
            )
        }
        let inputNode = engine.inputNode
        try setDevice(route.inputDevice.objectID, on: inputNode.audioUnit, role: "input")
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: route.sampleRate.hertz,
            channels: AVAudioChannelCount(route.inputDevice.inputChannelCount),
            interleaved: false
        ) else {
            throw failure(
                .incompatibleRoute,
                message: "The selected input cannot provide planar Float32 audio.",
                recovery: "Choose another input device or sample rate.",
                context: nil
            )
        }
        guard let newAccumulator = RecordingAccumulator(
            selectedChannel: route.inputChannel,
            sampleRate: route.sampleRate,
            bufferFrameCount: route.bufferFrameCount,
            maximumFrameCount: maximumFrameCount
        ) else {
            throw failure(
                .recordingFailed,
                message: "AudioLink Lab could not allocate the bounded capture buffer.",
                recovery: "Choose a shorter measurement window or close other applications.",
                context: "maximumFrameCount=\(maximumFrameCount)"
            )
        }
        accumulator = newAccumulator
        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(route.bufferFrameCount),
            format: inputFormat
        ) { buffer, time in
            newAccumulator.append(buffer: buffer, time: time)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            accumulator = nil
            throw failure(
                .engineStartFailed,
                message: "The audio engine could not start with the selected devices.",
                recovery: "Check Audio MIDI Setup, reconnect the devices, and try again.",
                context: error.localizedDescription
            )
        }
        engineStarted = true
        let engineStart = AudioEngineTimestamp(hostTime: AudioGetCurrentHostTime())
        let recordingStart = AudioEngineTimestamp(
            hostTime: AudioGetCurrentHostTime(),
            sampleTime: inputNode.lastRenderTime.map { Double($0.sampleTime) }
        )
        let timing = RecordingStart(engineStart: engineStart, recordingStart: recordingStart)
        recordingStartTiming = timing
        return timing
    }

    public func playPreparedSignal() async throws -> PlaybackTiming {
        guard engineStarted, let buffer = preparedBuffer else {
            throw failure(
                .playbackFailed,
                message: "Playback cannot begin because recording is not running.",
                recovery: "Restart the measurement.",
                context: nil
            )
        }
        let scheduled = AudioEngineTimestamp(
            hostTime: AudioGetCurrentHostTime(),
            sampleTime: player.lastRenderTime.map { Double($0.sampleTime) }
        )
        let gate = PlaybackCompletionGate<AudioEngineTimestamp>()
        let completed: AudioEngineTimestamp
        do {
            completed = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    guard gate.install(continuation) else { return }
                    guard !Task.isCancelled else {
                        gate.cancel()
                        return
                    }
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                        gate.finish(returning: AudioEngineTimestamp(hostTime: AudioGetCurrentHostTime()))
                    }
                    player.play()
                }
            }, onCancel: {
                gate.cancel()
                Task { await self.stopPlayback() }
            })
        } catch is CancellationError {
            await stopPlayback()
            throw CancellationError()
        } catch {
            await stopPlayback()
            throw failure(
                .playbackFailed,
                message: "Playback stopped before the test signal completed.",
                recovery: "Try the measurement again and check that the output device remains connected.",
                context: error.localizedDescription
            )
        }
        let timing = PlaybackTiming(scheduled: scheduled, completed: completed)
        playbackTiming = timing
        return timing
    }

    public func stopRecording() async throws -> RecordingCapture {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        engineStarted = false
        guard let accumulator else {
            throw failure(
                .recordingFailed,
                message: "No captured audio is available.",
                recovery: "Run the measurement again and verify the input route.",
                context: nil
            )
        }
        self.accumulator = nil
        return try accumulator.capture(
            startTiming: recordingStartTiming,
            playbackTiming: playbackTiming
        )
    }

    public func preview(signal: AudioSampleBuffer, route: AudioRouteConfiguration) async throws {
        try await preparePlayback(signal: signal, route: route)
        engine.prepare()
        do {
            try engine.start()
            engineStarted = true
            guard let buffer = preparedBuffer else {
                throw failure(
                    .playbackFailed,
                    message: "The preview signal was not prepared.",
                    recovery: "Generate the signal again.",
                    context: nil
                )
            }
            await withCheckedContinuation { continuation in
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    continuation.resume()
                }
                player.play()
            }
        } catch let known as RealtimeMeasurementFailure {
            await stopPlayback()
            throw known
        } catch {
            await stopPlayback()
            throw failure(
                .playbackFailed,
                message: "The test-signal preview could not be played.",
                recovery: "Check the selected output and volume, then try again.",
                context: error.localizedDescription
            )
        }
        await stopPlayback()
    }

    public func stopPlayback() async {
        player.stop()
        if engineStarted {
            engine.stop()
            engineStarted = false
        }
    }

    public func cancelRecording() async {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        engineStarted = false
        accumulator = nil
        recordingStartTiming = nil
    }

    private func makePlaybackBuffer(
        signal: AudioSampleBuffer,
        route: AudioRouteConfiguration
    ) throws -> AVAudioPCMBuffer {
        guard signal.frameCount <= Int(UInt32.max) else {
            throw failure(
                .signalGenerationFailed,
                message: "The generated signal is too long for the real-time playback buffer.",
                recovery: "Choose a shorter signal duration.",
                context: "frames=\(signal.frameCount)"
            )
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: route.sampleRate.hertz,
            channels: AVAudioChannelCount(route.outputDevice.outputChannelCount),
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(signal.frameCount)
        ), let channels = buffer.floatChannelData else {
            throw failure(
                .incompatibleRoute,
                message: "AudioLink Lab could not allocate an output buffer for this route.",
                recovery: "Choose another output device or a shorter signal.",
                context: nil
            )
        }
        buffer.frameLength = AVAudioFrameCount(signal.frameCount)
        for channel in 0..<route.outputDevice.outputChannelCount {
            channels[channel].initialize(repeating: 0, count: signal.frameCount)
        }
        try signal.withUnsafeChannelSamples(channel: 0) { source in
            guard let sourceAddress = source.baseAddress else { return }
            channels[route.outputChannel].update(from: sourceAddress, count: signal.frameCount)
        }
        return buffer
    }

    private func setDevice(_ objectID: UInt32?, on audioUnit: AudioUnit?, role: String) throws {
        guard let objectID, let audioUnit else {
            throw failure(
                role == "input" ? .inputDeviceUnavailable : .outputDeviceUnavailable,
                message: "The selected \(role) device cannot be routed by AVAudioEngine.",
                recovery: "Refresh devices and select a hardware endpoint again.",
                context: nil
            )
        }
        var mutableID = AudioDeviceID(objectID)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw failure(
                .incompatibleRoute,
                message: "AVAudioEngine could not select the requested \(role) device.",
                recovery: "Verify the device is connected and not exclusively in use.",
                context: "AudioUnitSetProperty OSStatus \(status)"
            )
        }
    }

    private func failure(
        _ code: RealtimeMeasurementFailureCode,
        message: String,
        recovery: String,
        context: String?
    ) -> RealtimeMeasurementFailure {
        RealtimeMeasurementFailure(
            code: code,
            userMessage: message,
            recoverySuggestion: recovery,
            technicalContext: context
        )
    }
}

private final class RecordingAccumulator: @unchecked Sendable {
    // The native buffer is a C11-atomic, single-producer capture store. The
    // pointer is created and destroyed outside the callback; append performs
    // only bounded pointer arithmetic, atomics and a memcpy. The actor calls
    // stop() before taking the snapshot, so the callback cannot mutate data
    // while Swift copies it.
    private let native: OpaquePointer
    private let selectedChannel: Int
    private let sampleRate: SampleRate
    private let bufferFrameCount: Int

    init?(
        selectedChannel: Int,
        sampleRate: SampleRate,
        bufferFrameCount: Int,
        maximumFrameCount: Int
    ) {
        self.selectedChannel = selectedChannel
        self.sampleRate = sampleRate
        self.bufferFrameCount = bufferFrameCount
        guard let native = al_recording_accumulator_create(maximumFrameCount) else { return nil }
        self.native = native
    }

    func append(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channels = buffer.floatChannelData,
              selectedChannel < Int(buffer.format.channelCount) else { return }
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

    func capture(
        startTiming: RecordingStart?,
        playbackTiming: PlaybackTiming?
    ) throws -> RecordingCapture {
        al_recording_accumulator_stop(native)
        let sampleCount = al_recording_accumulator_count(native)
        var samples = [Float](repeating: 0, count: sampleCount)
        samples.withUnsafeMutableBufferPointer { destination in
            al_recording_accumulator_copy(native, destination.baseAddress, sampleCount)
        }
        let firstSampleTime = al_recording_accumulator_has_first_sample_time(native) != 0
            ? al_recording_accumulator_first_sample_time(native) : nil
        let lastSampleTime = firstSampleTime == nil ? nil : al_recording_accumulator_last_sample_time(native)
        let recordedBufferCount = Int(min(UInt64(Int.max), al_recording_accumulator_buffer_count(native)))
        let overflowCount = Int(min(UInt64(Int.max), al_recording_accumulator_overflow_count(native)))
        let droppedBufferCount = Int(min(UInt64(Int.max), al_recording_accumulator_dropped_count(native)))

        let format = AudioFormatDescriptor(
            sampleRate: sampleRate,
            channelCount: 1,
            bitDepth: 32,
            isInterleaved: false
        )
        let audio = try AudioSampleBuffer(samples: samples, format: format)
        let beganBeforePlayback: Bool
        if let recordingHostTime = startTiming?.recordingStart.hostTime,
           let playbackHostTime = playbackTiming?.scheduled.hostTime {
            beganBeforePlayback = recordingHostTime <= playbackHostTime
        } else {
            beganBeforePlayback = false
        }
        let diagnostics = AudioEngineDiagnostics(
            engineStart: startTiming?.engineStart,
            recordingStart: startTiming?.recordingStart,
            playbackScheduled: playbackTiming?.scheduled,
            playbackCompletion: playbackTiming?.completed,
            firstRecordedSampleTime: firstSampleTime,
            lastRecordedSampleTime: lastSampleTime,
            bufferFrameCount: bufferFrameCount,
            recordedBufferCount: recordedBufferCount,
            overflowCount: overflowCount,
            droppedBufferCount: droppedBufferCount,
            nominalSampleRate: sampleRate,
            recordingBeganBeforePlayback: beganBeforePlayback,
            notes: [
                "The input tap is capture-only and is never connected to the output mixer.",
                "Capture storage is preallocated; the tap performs only bounded atomic counters and a sample copy."
            ]
        )
        return RecordingCapture(audio: audio, diagnostics: diagnostics)
    }

    deinit {
        al_recording_accumulator_stop(native)
        al_recording_accumulator_destroy(native)
    }
}
