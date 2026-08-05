import AudioLinkCore
import AudioLinkDSP
import Foundation

public actor RealtimeMeasurementEngine: RealtimeMeasurementRunning {
    private let deviceService: any AudioDeviceService
    private let permissionAuthorizer: any MicrophonePermissionAuthorizing
    private let playbackController: any PlaybackController
    private let recordingController: any RecordingController
    private let saver: any RealtimeMeasurementSaving
    private let signalGenerator: TestSignalGenerator
    private let preprocessor: AudioPreprocessor
    private let qualityAnalyzer: MeasurementQualityAnalyzer

    private var isRunning = false
    private var stopRequested = false
    private var eventTask: Task<Void, Never>?
    private var routeDiagnosticEvents: [AudioRouteDiagnosticEvent] = []

    public init(
        deviceService: any AudioDeviceService,
        permissionAuthorizer: any MicrophonePermissionAuthorizing,
        playbackController: any PlaybackController,
        recordingController: any RecordingController,
        saver: any RealtimeMeasurementSaving = NoopRealtimeMeasurementSaver(),
        signalGenerator: TestSignalGenerator = .init(),
        preprocessor: AudioPreprocessor = .init(),
        qualityAnalyzer: MeasurementQualityAnalyzer = .init()
    ) {
        self.deviceService = deviceService
        self.permissionAuthorizer = permissionAuthorizer
        self.playbackController = playbackController
        self.recordingController = recordingController
        self.saver = saver
        self.signalGenerator = signalGenerator
        self.preprocessor = preprocessor
        self.qualityAnalyzer = qualityAnalyzer
    }

    public func measure(
        configuration: RealtimeMeasurementConfiguration,
        stateHandler: (@Sendable (RealtimeMeasurementState) -> Void)? = nil
    ) async throws -> RealtimeMeasurementResult {
        guard !isRunning else {
            throw RealtimeMeasurementFailure(
                code: .alreadyRunning,
                userMessage: "A real-time measurement is already running.",
                recoverySuggestion: "Stop or wait for the current measurement before starting another.",
                technicalContext: nil
            )
        }
        isRunning = true
        stopRequested = false
        routeDiagnosticEvents = []
        let startedAt = Date()
        beginMonitoring(route: configuration.route)
        defer {
            eventTask?.cancel()
            eventTask = nil
            isRunning = false
        }

        do {
            update(.validatingDevices, handler: stateHandler)
            try validate(configuration)
            try await deviceService.validate(route: configuration.route)
            try ensureActive()

            update(.requestingPermission, handler: stateHandler)
            let permission = await permissionStatusRequestingIfNeeded()
            guard permission == .authorized else {
                throw RealtimeMeasurementFailure(
                    code: .permissionDenied,
                    userMessage: "Microphone access is required for real-time measurement.",
                    recoverySuggestion: "Allow AudioLink Lab in System Settings › Privacy & Security › Microphone, then try again.",
                    technicalContext: "permission=\(permission.rawValue)"
                )
            }
            try ensureActive()

            update(.preparingSignal, handler: stateHandler)
            let generated: GeneratedSignal
            do {
                generated = try signalGenerator.generate(configuration: configuration.signal)
            } catch {
                throw RealtimeMeasurementFailure(
                    code: .signalGenerationFailed,
                    userMessage: "The configured test signal could not be generated.",
                    recoverySuggestion: "Review duration, frequency, amplitude, and sample-rate settings.",
                    technicalContext: error.localizedDescription
                )
            }
            try await playbackController.preparePlayback(
                signal: generated.audio,
                route: configuration.route
            )
            try ensureActive()

            update(.startingRecording, handler: stateHandler)
            let maximumCaptureFrames = try maximumCaptureFrameCount(
                generatedSignalFrames: generated.audio.frameCount,
                configuration: configuration
            )
            _ = try await recordingController.startRecording(
                route: configuration.route,
                maximumFrameCount: maximumCaptureFrames
            )
            try ensureActive()

            update(.preRoll, handler: stateHandler)
            try await sleep(configuration.preRoll)
            try ensureActive()

            update(.playing, handler: stateHandler)
            _ = try await playbackController.playPreparedSignal()
            try ensureActive()

            update(.postRoll, handler: stateHandler)
            try await sleep(configuration.postRoll)
            try ensureActive()
            let captured = try await recordingController.stopRecording()
            await playbackController.stopPlayback()
            try ensureActive()

            update(.preprocessing, handler: stateHandler)
            let reference = try importedAudio(
                generated.audio,
                name: "Realtime Test Signal",
                metadata: ["source": "generated", "signalKind": configuration.signal.kind.rawValue]
            )
            let rawRecording = try importedAudio(
                captured.audio,
                name: "Realtime Recording",
                metadata: [
                    "source": "liveCapture",
                    "inputDeviceUID": configuration.route.inputDevice.id
                ]
            )
            let preparedRecording = try await preprocessor.process(
                rawRecording,
                configuration: configuration.preprocessing
            )
            try ensureActive()

            update(.analyzing, handler: stateHandler)
            var correlation = configuration.correlation
            correlation.channel = 0
            if correlation.sequenceOutput == .none {
                correlation.sequenceOutput = .searchedRange
            }
            let assessment: QualityAssessedMeasurement
            do {
                assessment = try await qualityAnalyzer.analyze(
                    reference: reference,
                    observed: preparedRecording,
                    correlationConfiguration: correlation
                )
            } catch {
                throw RealtimeMeasurementFailure(
                    code: .analysisFailed,
                    userMessage: "The recording did not produce a usable correlation result.",
                    recoverySuggestion: "Check routing and gain, reduce ambient noise, and measure again.",
                    technicalContext: error.localizedDescription
                )
            }
            try ensureActive()

            var calibratedAssessment = assessment
            if let profile = configuration.calibrationProfile {
                let route = CalibrationRouteDescriptor(
                    inputDeviceID: configuration.route.inputDevice.descriptor.id,
                    outputDeviceID: configuration.route.outputDevice.descriptor.id,
                    channelMapping: CalibrationChannelMapping(
                        inputChannel: configuration.route.inputChannel,
                        outputChannel: configuration.route.outputChannel
                    ),
                    sampleRate: configuration.route.sampleRate,
                    bufferFrameCount: configuration.route.bufferFrameCount
                )
                guard let rawDelay = assessment.delay else {
                    throw RealtimeMeasurementFailure(
                        code: .analysisFailed,
                        userMessage: "Calibration was selected, but the measurement did not produce a usable raw delay.",
                        recoverySuggestion: "Repeat the measurement before applying a calibration profile.",
                        technicalContext: "Calibration profile (profile.id) requires a raw DelayEstimate."
                    )
                }
                do {
                    let calibrated = try CalibrationApplicator.apply(
                        rawDelay: rawDelay,
                        profile: profile,
                        route: route,
                        subtractOffset: configuration.applyCalibrationOffset
                    )
                    calibratedAssessment = assessment.withCalibration(calibrated)
                } catch {
                    throw RealtimeMeasurementFailure(
                        code: .incompatibleRoute,
                        userMessage: "The selected calibration profile does not match the current audio route.",
                        recoverySuggestion: "Select a profile made for the same devices, channels, sample rate, and buffer size.",
                        technicalContext: error.localizedDescription
                    )
                }
            }

            let completedAt = Date()
            var result = RealtimeMeasurementResult(
                startedAt: startedAt,
                completedAt: completedAt,
                configuration: configuration,
                generatedSignal: generated,
                preparedReference: reference,
                preparedRecording: preparedRecording,
                assessment: calibratedAssessment,
                diagnostics: mergingRouteEvents(into: captured.diagnostics)
            )
            update(.saving, handler: stateHandler)
            do {
                let historyID = try await saver.save(result: result)
                result = result.withSavedHistorySessionID(historyID)
            } catch {
                throw RealtimeMeasurementFailure(
                    code: .saveFailed,
                    userMessage: "The measurement completed, but its history record could not be saved.",
                    recoverySuggestion: "Review the result now and check local storage before measuring again.",
                    technicalContext: error.localizedDescription
                )
            }
            update(.completed, handler: stateHandler)
            return result
        } catch is CancellationError {
            await safelyStopControllers()
            update(.cancelled, handler: stateHandler)
            throw RealtimeMeasurementFailure(
                code: .cancelled,
                userMessage: "The real-time measurement was cancelled.",
                recoverySuggestion: "Verify the route before starting again.",
                technicalContext: nil
            )
        } catch let failure as RealtimeMeasurementFailure {
            await safelyStopControllers()
            if failure.code == .cancelled || stopRequested {
                update(.cancelled, handler: stateHandler)
            } else {
                update(.failed(failure), handler: stateHandler)
            }
            throw failure
        } catch {
            await safelyStopControllers()
            let failure = RealtimeMeasurementFailure(
                code: .recordingFailed,
                userMessage: "The real-time audio pipeline stopped unexpectedly.",
                recoverySuggestion: "Reconnect the selected devices and try again.",
                technicalContext: error.localizedDescription
            )
            update(.failed(failure), handler: stateHandler)
            throw failure
        }
    }

    public func preview(configuration: RealtimeMeasurementConfiguration) async throws {
        guard !isRunning else {
            throw RealtimeMeasurementFailure(
                code: .alreadyRunning,
                userMessage: "A measurement is already using the audio engine.",
                recoverySuggestion: "Stop the measurement before previewing the signal.",
                technicalContext: nil
            )
        }
        try validate(configuration)
        try await deviceService.validate(route: configuration.route)
        let generated = try signalGenerator.generate(configuration: configuration.signal)
        try await playbackController.preview(signal: generated.audio, route: configuration.route)
    }

    public func stop() async {
        guard isRunning else { return }
        stopRequested = true
        await safelyStopControllers()
    }

    private func permissionStatusRequestingIfNeeded() async -> MicrophonePermissionStatus {
        let status = await permissionAuthorizer.status()
        return status == .notDetermined
            ? await permissionAuthorizer.requestPermission()
            : status
    }

    private func validate(_ configuration: RealtimeMeasurementConfiguration) throws {
        guard configuration.signal.sampleRate == configuration.route.sampleRate else {
            throw RealtimeMeasurementFailure(
                code: .sampleRateMismatch,
                userMessage: "The signal and audio route must use the same sample rate.",
                recoverySuggestion: "Regenerate the signal at (Int(configuration.route.sampleRate.hertz)) Hz.",
                technicalContext: "signal=\(configuration.signal.sampleRate.hertz), route=\(configuration.route.sampleRate.hertz)"
            )
        }
        guard configuration.signal.channelCount == 1 else {
            throw RealtimeMeasurementFailure(
                code: .incompatibleRoute,
                userMessage: "Real-time measurement currently requires a mono reference signal.",
                recoverySuggestion: "Set the generated signal channel count to one; choose the physical output channel separately.",
                technicalContext: "signalChannels=\(configuration.signal.channelCount)"
            )
        }
        if let targetRate = configuration.preprocessing.targetSampleRate,
           targetRate != configuration.route.sampleRate {
            throw RealtimeMeasurementFailure(
                code: .sampleRateMismatch,
                userMessage: "Implicit resampling is disabled for real-time delay analysis.",
                recoverySuggestion: "Use the route sample rate for preprocessing and analysis.",
                technicalContext: "target=\(targetRate.hertz), route=\(configuration.route.sampleRate.hertz)"
            )
        }
    }

    private func importedAudio(
        _ audio: AudioSampleBuffer,
        name: String,
        metadata: [String: String]
    ) throws -> ImportedAudioFile {
        let analysis = AudioMetricsAnalyzer().analyze(audio)
        return ImportedAudioFile(
            fileURL: URL(fileURLWithPath: "/AudioLinkRealtime/\(name.replacingOccurrences(of: " ", with: "-"))"),
            fileName: name,
            originalFormat: AudioFileFormatDescription(
                container: .unknown,
                encoding: .ieeeFloat,
                sampleRate: audio.format.sampleRate,
                channelCount: audio.channelCount,
                bitDepth: 32,
                isInterleaved: false,
                isBigEndian: false,
                formatIdentifier: "realtime-float32"
            ),
            audio: audio,
            analysis: analysis,
            metadata: metadata
        )
    }

    private func sleep(_ duration: DurationSeconds) async throws {
        guard duration.value > 0 else { return }
        try await Task.sleep(for: .seconds(duration.value))
    }

    private func maximumCaptureFrameCount(
        generatedSignalFrames: Int,
        configuration: RealtimeMeasurementConfiguration
    ) throws -> Int {
        let preFrames = configuration.preRoll.sampleCount(at: configuration.route.sampleRate).rawValue
        let postFrames = configuration.postRoll.sampleCount(at: configuration.route.sampleRate).rawValue
        let slackFrames = Int64(configuration.route.bufferFrameCount) * 8
        let (silenceFrames, silenceOverflow) = preFrames.addingReportingOverflow(postFrames)
        let (contentFrames, contentOverflow) = Int64(generatedSignalFrames).addingReportingOverflow(silenceFrames)
        let (totalFrames, totalOverflow) = contentFrames.addingReportingOverflow(slackFrames)
        guard !silenceOverflow, !contentOverflow, !totalOverflow,
              totalFrames > 0, totalFrames <= Int64(Int.max),
              totalFrames <= 50_000_000 else {
            throw RealtimeMeasurementFailure(
                code: .recordingFailed,
                userMessage: "The requested real-time capture window is too large for a bounded safe buffer.",
                recoverySuggestion: "Reduce the signal, pre-roll, or post-roll duration to 50 million frames or fewer.",
                technicalContext: nil
            )
        }
        return Int(totalFrames)
    }

    private func ensureActive() throws {
        if Task.isCancelled || stopRequested { throw CancellationError() }
    }

    private func update(
        _ state: RealtimeMeasurementState,
        handler: (@Sendable (RealtimeMeasurementState) -> Void)?
    ) {
        handler?(state)
    }

    private func beginMonitoring(route: AudioRouteConfiguration) {
        eventTask?.cancel()
        let stream = deviceService.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(event: event, route: route)
            }
        }
    }

    private func handle(event: AudioDeviceEvent, route: AudioRouteConfiguration) async {
        routeDiagnosticEvents.append(
            AudioRouteDiagnosticEvent(description: String(describing: event))
        )
        let shouldStop: Bool
        switch event {
        case let .disconnected(uid):
            shouldStop = uid == route.inputDevice.id || uid == route.outputDevice.id
        case let .nominalSampleRateChanged(uid, _, _):
            shouldStop = uid == route.inputDevice.id || uid == route.outputDevice.id
        case .defaultInputChanged, .defaultOutputChanged, .deviceListChanged:
            shouldStop = false
        }
        if shouldStop {
            stopRequested = true
            await safelyStopControllers()
        }
    }

    private func safelyStopControllers() async {
        await playbackController.stopPlayback()
        await recordingController.cancelRecording()
    }

    private func mergingRouteEvents(into diagnostics: AudioEngineDiagnostics) -> AudioEngineDiagnostics {
        AudioEngineDiagnostics(
            engineStart: diagnostics.engineStart,
            recordingStart: diagnostics.recordingStart,
            playbackScheduled: diagnostics.playbackScheduled,
            playbackCompletion: diagnostics.playbackCompletion,
            firstRecordedSampleTime: diagnostics.firstRecordedSampleTime,
            lastRecordedSampleTime: diagnostics.lastRecordedSampleTime,
            bufferFrameCount: diagnostics.bufferFrameCount,
            recordedBufferCount: diagnostics.recordedBufferCount,
            underflowCount: diagnostics.underflowCount,
            overflowCount: diagnostics.overflowCount,
            droppedBufferCount: diagnostics.droppedBufferCount,
            routeChanges: diagnostics.routeChanges + routeDiagnosticEvents,
            nominalSampleRate: diagnostics.nominalSampleRate,
            recordingBeganBeforePlayback: diagnostics.recordingBeganBeforePlayback,
            notes: diagnostics.notes
        )
    }
}
