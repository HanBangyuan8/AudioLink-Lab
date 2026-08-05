import AudioLinkCore
import AudioLinkDSP
import XCTest
@testable import AudioLinkRealtime

final class RealtimeMeasurementEngineTests: XCTestCase {
    func testPhysicalLoopbackCalibratorCreatesRouteSpecificProfile() async throws {
        let fixture = try Fixture(delaySamples: 240)
        let profile = try await PhysicalLoopbackCalibrator(runner: fixture.engine).measure(
            configuration: fixture.configuration,
            profileName: "Physical loopback"
        )
        XCTAssertEqual(profile.calibrationMethod, .physicalLoopback)
        XCTAssertEqual(profile.knownFixedDelay.sampleCount.rawValue, 240)
        XCTAssertEqual(profile.inputDevice.id, fixture.configuration.route.inputDevice.descriptor.id)
    }

    func testSuccessfulLoopbackUsesCorrelationDelayAndSavesResult() async throws {
        let fixture = try Fixture(delaySamples: 240)
        let states = StateRecorder()

        let result = try await fixture.engine.measure(configuration: fixture.configuration) { state in
            states.append(state)
        }

        XCTAssertEqual(result.assessment.delay?.sampleOffset.rawValue, 240)
        XCTAssertEqual(result.savedHistorySessionID, fixture.savedID)
        XCTAssertTrue(result.diagnostics.recordingBeganBeforePlayback)
        let startCount = await fixture.io.startCount
        let saveCount = await fixture.saver.saveCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(saveCount, 1)
        XCTAssertLessThan(
            states.values.firstIndex(of: .startingRecording) ?? .max,
            states.values.firstIndex(of: .playing) ?? .max
        )
        XCTAssertEqual(states.values.last, .completed)
    }

    func testPermissionDeniedDoesNotStartEngine() async throws {
        let fixture = try Fixture(permission: .denied)

        await XCTAssertThrowsRealtime(code: .permissionDenied) {
            _ = try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)
        }
        let startCount = await fixture.io.startCount
        XCTAssertEqual(startCount, 0)
    }

    func testPermissionIsRequestedOnlyWhenUndetermined() async throws {
        let permission = MockPermission(status: .notDetermined, requestResult: .authorized)
        let fixture = try Fixture(permissionAuthorizer: permission)

        _ = try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)

        let requestCount = await permission.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testRecordingFailureStopsControllers() async throws {
        let fixture = try Fixture()
        await fixture.io.setFailure(.recording)

        await XCTAssertThrowsRealtime(code: .recordingFailed) {
            _ = try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)
        }
        let cancelCount = await fixture.io.cancelCount
        XCTAssertGreaterThan(cancelCount, 0)
    }

    func testPlaybackFailureStopsRecording() async throws {
        let fixture = try Fixture()
        await fixture.io.setFailure(.playback)

        await XCTAssertThrowsRealtime(code: .playbackFailed) {
            _ = try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)
        }
        let cancelCount = await fixture.io.cancelCount
        XCTAssertGreaterThan(cancelCount, 0)
    }

    func testAnalysisFailureIsMapped() async throws {
        let fixture = try Fixture()
        await fixture.io.setCaptureSampleRate(.hz44100)

        await XCTAssertThrowsRealtime(code: .analysisFailed) {
            _ = try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)
        }
    }

    func testExplicitStopCancelsMeasurement() async throws {
        let fixture = try Fixture(holdPlayback: true)
        let task = Task {
            try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)
        }
        try await Task.sleep(for: .milliseconds(30))

        await fixture.engine.stop()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let failure as RealtimeMeasurementFailure {
            XCTAssertEqual(failure.code, .cancelled)
        }
        let cancelCount = await fixture.io.cancelCount
        XCTAssertGreaterThan(cancelCount, 0)
    }

    func testSelectedDeviceDisconnectSafelyCancelsMeasurement() async throws {
        let fixture = try Fixture(holdPlayback: true)
        let task = Task {
            try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)
        }
        try await Task.sleep(for: .milliseconds(30))

        fixture.devices.send(.disconnected(uid: fixture.input.id))

        do {
            _ = try await task.value
            XCTFail("Expected device cancellation")
        } catch let failure as RealtimeMeasurementFailure {
            XCTAssertEqual(failure.code, .cancelled)
        }
        let cancelCount = await fixture.io.cancelCount
        XCTAssertGreaterThan(cancelCount, 0)
    }

    func testSecondStartIsRejectedWithoutStartingEngineTwice() async throws {
        let fixture = try Fixture(holdPlayback: true)
        let first = Task {
            try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)
        }
        try await Task.sleep(for: .milliseconds(30))

        await XCTAssertThrowsRealtime(code: .alreadyRunning) {
            _ = try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)
        }
        await fixture.engine.stop()
        _ = try? await first.value
        let startCount = await fixture.io.startCount
        XCTAssertEqual(startCount, 1)
    }

    func testSampleRateChangeOnSelectedRouteCancelsMeasurement() async throws {
        let fixture = try Fixture(holdPlayback: true)
        let task = Task {
            try await fixture.engine.measure(configuration: fixture.configuration, stateHandler: nil)
        }
        try await Task.sleep(for: .milliseconds(30))

        fixture.devices.send(
            .nominalSampleRateChanged(uid: fixture.output.id, oldValue: .hz48000, newValue: .hz44100)
        )

        do {
            _ = try await task.value
            XCTFail("Expected cancellation after route sample-rate change")
        } catch let failure as RealtimeMeasurementFailure {
            XCTAssertEqual(failure.code, .cancelled)
        }
    }

    func testPreviewDoesNotRequestMicrophonePermissionOrStartRecording() async throws {
        let permission = MockPermission(status: .notDetermined, requestResult: .denied)
        let fixture = try Fixture(permissionAuthorizer: permission)

        try await fixture.engine.preview(configuration: fixture.configuration)

        let requestCount = await permission.requestCount
        let startCount = await fixture.io.startCount
        let previewCount = await fixture.io.previewCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(previewCount, 1)
    }
}

private extension RealtimeMeasurementEngineTests {
    struct Fixture {
        let input: AudioDeviceDescription
        let output: AudioDeviceDescription
        let devices: MockDeviceService
        let io: MockRealtimeIO
        let saver: MockSaver
        let engine: RealtimeMeasurementEngine
        let configuration: RealtimeMeasurementConfiguration
        let savedID = UUID()

        init(
            delaySamples: Int = 120,
            permission: MicrophonePermissionStatus = .authorized,
            permissionAuthorizer: MockPermission? = nil,
            holdPlayback: Bool = false
        ) throws {
            input = makeDevice(uid: "input", name: "Mock Input", inputs: 2, outputs: 0, defaultInput: true)
            output = makeDevice(uid: "output", name: "Mock Output", inputs: 0, outputs: 2, defaultOutput: true)
            devices = MockDeviceService(devices: [input, output])
            io = MockRealtimeIO(delaySamples: delaySamples, holdPlayback: holdPlayback)
            saver = MockSaver(id: savedID)
            let permissionService = permissionAuthorizer ?? MockPermission(status: permission, requestResult: permission)
            engine = RealtimeMeasurementEngine(
                deviceService: devices,
                permissionAuthorizer: permissionService,
                playbackController: io,
                recordingController: io,
                saver: saver
            )
            let route = AudioRouteConfiguration(
                inputDevice: input,
                outputDevice: output,
                inputChannel: 0,
                outputChannel: 0,
                sampleRate: .hz48000,
                bufferFrameCount: 256
            )
            configuration = RealtimeMeasurementConfiguration(
                route: route,
                signal: TestSignalConfiguration(
                    kind: .bandLimitedNoise,
                    sampleRate: .hz48000,
                    duration: try DurationSeconds(0.08),
                    startFrequencyHertz: 200,
                    endFrequencyHertz: 12_000,
                    amplitude: 0.25,
                    fadeIn: try DurationSeconds(0.002),
                    fadeOut: try DurationSeconds(0.002),
                    channelCount: 1,
                    deterministicSeed: 42
                ),
                preRoll: .zero,
                postRoll: .zero,
                correlation: CorrelationConfiguration(
                    method: .automatic,
                    normalization: .overlapEnergy,
                    searchRange: SampleLagRange(minimum: 0, maximum: 1_000),
                    peakSelection: .absolute,
                    sequenceOutput: .searchedRange,
                    minimumOverlapRatio: 0.5
                ),
                preprocessing: PreprocessingConfiguration(removeDCOffset: true)
            )
        }
    }

    static func makeDevice(
        uid: String,
        name: String,
        inputs: Int,
        outputs: Int,
        defaultInput: Bool = false,
        defaultOutput: Bool = false
    ) -> AudioDeviceDescription {
        AudioDeviceDescription(
            descriptor: DeviceDescriptor(
                id: uid,
                name: name,
                transport: .virtual,
                supportsInput: inputs > 0,
                supportsOutput: outputs > 0
            ),
            objectID: uid == "input" ? 1 : 2,
            nominalSampleRate: .hz48000,
            inputChannelCount: inputs,
            outputChannelCount: outputs,
            isDefaultInput: defaultInput,
            isDefaultOutput: defaultOutput
        )
    }

    func XCTAssertThrowsRealtime(
        code: RealtimeMeasurementFailureCode,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch let failure as RealtimeMeasurementFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RealtimeMeasurementState] = []

    var values: [RealtimeMeasurementState] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ state: RealtimeMeasurementState) {
        lock.lock()
        storage.append(state)
        lock.unlock()
    }
}

private final class MockDeviceService: AudioDeviceService, @unchecked Sendable {
    private let allDevices: [AudioDeviceDescription]
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioDeviceEvent>.Continuation?

    init(devices: [AudioDeviceDescription]) { allDevices = devices }

    func devices() async throws -> [AudioDeviceDescription] { allDevices }
    func defaultInputDevice() async throws -> AudioDeviceDescription? { allDevices.first(where: \.isDefaultInput) }
    func defaultOutputDevice() async throws -> AudioDeviceDescription? { allDevices.first(where: \.isDefaultOutput) }

    func validate(route: AudioRouteConfiguration) async throws {
        guard allDevices.contains(where: { $0.id == route.inputDevice.id }) else {
            throw RealtimeMeasurementFailure(
                code: .inputDeviceUnavailable,
                userMessage: "missing input",
                recoverySuggestion: "refresh",
                technicalContext: nil
            )
        }
    }

    func events() -> AsyncStream<AudioDeviceEvent> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func send(_ event: AudioDeviceEvent) {
        lock.lock()
        let target = continuation
        lock.unlock()
        target?.yield(event)
    }
}

private actor MockPermission: MicrophonePermissionAuthorizing {
    private let initialStatus: MicrophonePermissionStatus
    private let requestResult: MicrophonePermissionStatus
    private(set) var requestCount = 0

    init(status: MicrophonePermissionStatus, requestResult: MicrophonePermissionStatus) {
        initialStatus = status
        self.requestResult = requestResult
    }

    func status() async -> MicrophonePermissionStatus { initialStatus }
    func requestPermission() async -> MicrophonePermissionStatus {
        requestCount += 1
        return requestResult
    }
}

private actor MockSaver: RealtimeMeasurementSaving {
    let id: UUID
    private(set) var saveCount = 0
    init(id: UUID) { self.id = id }
    func save(result: RealtimeMeasurementResult) async throws -> UUID? {
        saveCount += 1
        return id
    }
}

private actor MockRealtimeIO: PlaybackController, RecordingController {
    enum Failure { case none, playback, recording }

    private let delaySamples: Int
    private let holdPlayback: Bool
    private var signal: AudioSampleBuffer?
    private var route: AudioRouteConfiguration?
    private var stopped = false
    private var failure: Failure = .none
    private var captureSampleRate: SampleRate?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var previewCount = 0

    init(delaySamples: Int, holdPlayback: Bool) {
        self.delaySamples = delaySamples
        self.holdPlayback = holdPlayback
    }

    func setFailure(_ value: Failure) { failure = value }
    func setCaptureSampleRate(_ value: SampleRate) { captureSampleRate = value }

    func preparePlayback(signal: AudioSampleBuffer, route: AudioRouteConfiguration) async throws {
        self.signal = signal
        self.route = route
        stopped = false
    }

    func startRecording(
        route: AudioRouteConfiguration,
        maximumFrameCount: Int
    ) async throws -> RecordingStart {
        if failure == .recording {
            throw RealtimeMeasurementFailure(
                code: .recordingFailed,
                userMessage: "mock recording failure",
                recoverySuggestion: "retry",
                technicalContext: nil
            )
        }
        startCount += 1
        let engine = AudioEngineTimestamp(hostTime: 100)
        return RecordingStart(
            engineStart: engine,
            recordingStart: AudioEngineTimestamp(hostTime: 110, sampleTime: 0)
        )
    }

    func playPreparedSignal() async throws -> PlaybackTiming {
        if failure == .playback {
            throw RealtimeMeasurementFailure(
                code: .playbackFailed,
                userMessage: "mock playback failure",
                recoverySuggestion: "retry",
                technicalContext: nil
            )
        }
        if holdPlayback {
            for _ in 0..<100 {
                if stopped {
                    throw RealtimeMeasurementFailure(
                        code: .cancelled,
                        userMessage: "stopped",
                        recoverySuggestion: "retry",
                        technicalContext: nil
                    )
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return PlaybackTiming(
            scheduled: AudioEngineTimestamp(hostTime: 200, sampleTime: 0),
            completed: AudioEngineTimestamp(hostTime: 300)
        )
    }

    func stopRecording() async throws -> RecordingCapture {
        guard let signal, let route else {
            throw RealtimeMeasurementFailure(
                code: .recordingFailed,
                userMessage: "missing mock signal",
                recoverySuggestion: "retry",
                technicalContext: nil
            )
        }
        let rate = captureSampleRate ?? route.sampleRate
        var observed = [Float](repeating: 0, count: delaySamples + signal.frameCount + 128)
        try signal.withUnsafeChannelSamples(channel: 0) { samples in
            for index in samples.indices {
                observed[delaySamples + index] = samples[index]
            }
        }
        let audio = try AudioSampleBuffer(
            samples: observed,
            format: AudioFormatDescriptor(
                sampleRate: rate,
                channelCount: 1,
                bitDepth: 32,
                isInterleaved: false
            )
        )
        return RecordingCapture(
            audio: audio,
            diagnostics: AudioEngineDiagnostics(
                engineStart: AudioEngineTimestamp(hostTime: 100),
                recordingStart: AudioEngineTimestamp(hostTime: 110, sampleTime: 0),
                playbackScheduled: AudioEngineTimestamp(hostTime: 200, sampleTime: 0),
                playbackCompletion: AudioEngineTimestamp(hostTime: 300),
                firstRecordedSampleTime: 0,
                lastRecordedSampleTime: Double(observed.count - 1),
                bufferFrameCount: route.bufferFrameCount,
                recordedBufferCount: 4,
                nominalSampleRate: rate,
                recordingBeganBeforePlayback: true
            )
        )
    }

    func preview(signal: AudioSampleBuffer, route: AudioRouteConfiguration) async throws {
        previewCount += 1
    }

    func stopPlayback() async { stopped = true }
    func cancelRecording() async {
        stopped = true
        cancelCount += 1
    }
}
