import AppKit
import AudioLinkCore
import AudioLinkDSP
import AudioLinkRealtime
import AudioLinkStorage
import Combine
import Foundation

@MainActor
final class RealtimeMeasurementViewModel: ObservableObject {
    @Published private(set) var devices: [AudioDeviceDescription] = []
    @Published var selectedInputID: String? { didSet { routeSelectionChanged() } }
    @Published var selectedOutputID: String? { didSet { routeSelectionChanged() } }
    @Published var inputChannel = 0 { didSet { invalidateResult() } }
    @Published var outputChannel = 0 { didSet { invalidateResult() } }
    @Published var bufferFrameCount = 512 { didSet { invalidateResult() } }
    @Published var signalDurationSeconds = 0.5 { didSet { invalidateResult() } }
    @Published var amplitude = 0.18 { didSet { invalidateResult() } }
    @Published var preRollSeconds = 0.25 { didSet { invalidateResult() } }
    @Published var postRollSeconds = 0.5 { didSet { invalidateResult() } }
    @Published var maximumDelayMilliseconds = 1_000.0 { didSet { invalidateResult() } }
    @Published var removeDCOffset = true { didSet { invalidateResult() } }
    @Published var highPassEnabled = false { didSet { invalidateResult() } }
    @Published var acknowledgedVolumeWarning = false
    @Published var acknowledgedFeedbackWarning = false
    @Published private(set) var state: RealtimeMeasurementState = .idle
    @Published private(set) var result: RealtimeMeasurementResult?
    @Published private(set) var failure: RealtimeMeasurementFailure?
    @Published private(set) var isRefreshingDevices = false
    @Published private(set) var latestRouteEvent: String?
    @Published private(set) var calibrationProfiles: [CalibrationProfile] = []
    @Published var selectedCalibrationProfileID: UUID? { didSet { invalidateResult() } }
    @Published var applyCalibrationOffset = false { didSet { invalidateResult() } }

    private let deviceService: any AudioDeviceService
    private let runner: any RealtimeMeasurementRunning
    private let calibrationRepository: (any MeasurementRepository)?
    private var measurementTask: Task<Void, Never>?
    private var deviceEventTask: Task<Void, Never>?
    private var suppressSelectionInvalidation = false

    init(
        deviceService: any AudioDeviceService,
        runner: any RealtimeMeasurementRunning,
        calibrationRepository: (any MeasurementRepository)? = nil
    ) {
        self.deviceService = deviceService
        self.runner = runner
        self.calibrationRepository = calibrationRepository
        deviceEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in deviceService.events() {
                guard !Task.isCancelled else { return }
                self.latestRouteEvent = Self.description(for: event)
                await self.refreshDevices()
            }
        }
        Task { [weak self] in await self?.refreshDevices() }
        Task { [weak self] in await self?.refreshCalibrationProfiles() }
    }

    deinit {
        measurementTask?.cancel()
        deviceEventTask?.cancel()
    }

    var inputDevices: [AudioDeviceDescription] { devices.filter { $0.inputChannelCount > 0 } }
    var outputDevices: [AudioDeviceDescription] { devices.filter { $0.outputChannelCount > 0 } }
    var selectedInput: AudioDeviceDescription? { inputDevices.first { $0.id == selectedInputID } }
    var selectedOutput: AudioDeviceDescription? { outputDevices.first { $0.id == selectedOutputID } }
    var selectedCalibrationProfile: CalibrationProfile? { calibrationProfiles.first { $0.id == selectedCalibrationProfileID } }

    var routeRatesMatch: Bool {
        guard let selectedInput, let selectedOutput else { return false }
        return abs(selectedInput.nominalSampleRate.hertz - selectedOutput.nominalSampleRate.hertz) < 0.5
    }

    var canStart: Bool {
        selectedInput != nil && selectedOutput != nil && routeRatesMatch
            && acknowledgedVolumeWarning && acknowledgedFeedbackWarning
            && !state.isBusy
    }

    var canPreview: Bool {
        selectedOutput != nil && selectedInput != nil && routeRatesMatch
            && acknowledgedVolumeWarning && !state.isBusy
    }

    func refreshDevices() async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }
        do {
            let refreshed = try await deviceService.devices()
            suppressSelectionInvalidation = true
            devices = refreshed
            if selectedInput == nil {
                selectedInputID = refreshed.first(where: \.isDefaultInput)?.id
                    ?? refreshed.first(where: { $0.inputChannelCount > 0 })?.id
            }
            if selectedOutput == nil {
                selectedOutputID = refreshed.first(where: \.isDefaultOutput)?.id
                    ?? refreshed.first(where: { $0.outputChannelCount > 0 })?.id
            }
            clampChannels()
            suppressSelectionInvalidation = false
            failure = nil
        } catch {
            failure = map(error, fallbackCode: .incompatibleRoute)
        }
    }

    func refreshCalibrationProfiles() async {
        guard let calibrationRepository else { return }
        do {
            calibrationProfiles = try await calibrationRepository.calibrationProfiles()
            if selectedCalibrationProfile == nil { selectedCalibrationProfileID = nil }
        } catch {
            calibrationProfiles = []
        }
    }

    func startMeasurement() {
        guard !state.isBusy else { return }
        do {
            let configuration = try makeConfiguration()
            result = nil
            failure = nil
            state = .validatingDevices
            let runner = self.runner
            let stateRelay = RealtimeMeasurementStateRelay(viewModel: self)
            measurementTask = Task { [weak self] in
                do {
                    let result = try await runner.measure(configuration: configuration) { state in
                        stateRelay.send(state)
                    }
                    guard !Task.isCancelled, let self else { return }
                    self.result = result
                    self.state = .completed
                    self.measurementTask = nil
                } catch {
                    guard let self else { return }
                    let mapped = self.map(error, fallbackCode: .recordingFailed)
                    self.failure = mapped.code == .cancelled ? nil : mapped
                    self.state = mapped.code == .cancelled ? .cancelled : .failed(mapped)
                    self.measurementTask = nil
                }
            }
        } catch {
            let mapped = map(error, fallbackCode: .incompatibleRoute)
            failure = mapped
            state = .failed(mapped)
        }
    }

    func previewSignal() {
        guard canPreview else { return }
        do {
            let configuration = try makeConfiguration()
            let runner = self.runner
            failure = nil
            measurementTask = Task { [weak self] in
                do {
                    try await runner.preview(configuration: configuration)
                    guard let self else { return }
                    self.measurementTask = nil
                } catch {
                    guard let self else { return }
                    let mapped = self.map(error, fallbackCode: .playbackFailed)
                    self.failure = mapped
                    self.state = .failed(mapped)
                    self.measurementTask = nil
                }
            }
        } catch {
            failure = map(error, fallbackCode: .signalGenerationFailed)
        }
    }

    func stop() {
        guard state.isBusy else { return }
        measurementTask?.cancel()
        measurementTask = nil
        let runner = self.runner
        Task { await runner.stop() }
        result = nil
        failure = nil
        state = .cancelled
    }

    func recover() {
        failure = nil
        state = .idle
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyResult() {
        guard let result else { return }
        let delay = result.assessment.delay
        let lines = [
            "AudioLink Lab Real-time Measurement",
            "delay_ms: \(delay.map { String(format: "%.6f", $0.fractionalMilliseconds) } ?? "unavailable")",
            "delay_samples: \(delay.map { String($0.sampleOffset.rawValue) } ?? "unavailable")",
            "fractional_samples: \(delay?.fractionalSampleOffset.map { String(format: "%.6f", $0) } ?? "unavailable")",
            "calibrated_delay_ms: \(result.assessment.calibration.flatMap { $0.calibratedDelay?.fractionalMilliseconds }.map { String(format: "%.6f", $0) } ?? "unavailable")",
            "quality: \(result.assessment.quality.level.rawValue)",
            "confidence: \(String(format: "%.4f", result.assessment.quality.confidence.value))",
            "input_device: \(result.configuration.route.inputDevice.name)",
            "output_device: \(result.configuration.route.outputDevice.name)",
            "recording_started_before_playback: \(result.diagnostics.recordingBeganBeforePlayback)",
            "dropped_buffers: \(result.diagnostics.droppedBufferCount)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func waitForMeasurement() async { await measurementTask?.value }

    func makeStabilityBaseConfiguration() throws -> RealtimeMeasurementConfiguration {
        try makeConfiguration()
    }

    private func makeConfiguration() throws -> RealtimeMeasurementConfiguration {
        guard let input = selectedInput, let output = selectedOutput else {
            throw RealtimeMeasurementFailure(
                code: .incompatibleRoute,
                userMessage: "Choose both an input and an output device.",
                recoverySuggestion: "Refresh devices, then select the endpoints to measure.",
                technicalContext: nil
            )
        }
        let route = AudioRouteConfiguration(
            inputDevice: input,
            outputDevice: output,
            inputChannel: inputChannel,
            outputChannel: outputChannel,
            sampleRate: input.nominalSampleRate,
            bufferFrameCount: bufferFrameCount
        )
        let duration = try DurationSeconds(signalDurationSeconds)
        let preRoll = try DurationSeconds(preRollSeconds)
        let postRoll = try DurationSeconds(postRollSeconds)
        let maximumLag = Int64((maximumDelayMilliseconds / 1_000 * route.sampleRate.hertz).rounded())
        return RealtimeMeasurementConfiguration(
            route: route,
            signal: TestSignalConfiguration(
                kind: .logarithmicSweep,
                sampleRate: route.sampleRate,
                duration: duration,
                startFrequencyHertz: 80,
                endFrequencyHertz: min(18_000, route.sampleRate.hertz * 0.45),
                amplitude: Float(amplitude),
                fadeIn: try DurationSeconds(min(0.01, signalDurationSeconds / 4)),
                fadeOut: try DurationSeconds(min(0.01, signalDurationSeconds / 4)),
                channelCount: 1,
                deterministicSeed: 0xA0D1_01A5
            ),
            preRoll: preRoll,
            postRoll: postRoll,
            correlation: CorrelationConfiguration(
                method: .automatic,
                normalization: .overlapEnergy,
                searchRange: SampleLagRange(minimum: 0, maximum: maximumLag),
                peakSelection: .absolute,
                sequenceOutput: .searchedRange,
                minimumOverlapRatio: 0.35,
                interpolateSubsample: true,
                channel: 0
            ),
            preprocessing: PreprocessingConfiguration(
                removeDCOffset: removeDCOffset,
                highPassFilter: highPassEnabled
                    ? HighPassFilterConfiguration(cutoffFrequencyHertz: 20)
                    : nil
            ),
            calibrationProfile: selectedCalibrationProfile,
            applyCalibrationOffset: applyCalibrationOffset
        )
    }

    private func routeSelectionChanged() {
        guard !suppressSelectionInvalidation else { return }
        clampChannels()
        invalidateResult()
    }

    private func clampChannels() {
        inputChannel = min(inputChannel, max(0, (selectedInput?.inputChannelCount ?? 1) - 1))
        outputChannel = min(outputChannel, max(0, (selectedOutput?.outputChannelCount ?? 1) - 1))
    }

    private func invalidateResult() {
        guard !state.isBusy else { return }
        result = nil
        failure = nil
        if case .idle = state { return }
        state = .idle
    }

    private func map(
        _ error: any Error,
        fallbackCode: RealtimeMeasurementFailureCode
    ) -> RealtimeMeasurementFailure {
        if let realtime = error as? RealtimeMeasurementFailure { return realtime }
        if error is CancellationError {
            return RealtimeMeasurementFailure(
                code: .cancelled,
                userMessage: "The measurement was cancelled.",
                recoverySuggestion: "Check the route before starting again.",
                technicalContext: nil
            )
        }
        return RealtimeMeasurementFailure(
            code: fallbackCode,
            userMessage: "The real-time measurement could not continue.",
            recoverySuggestion: "Check the selected devices and try again.",
            technicalContext: error.localizedDescription
        )
    }

    private static func description(for event: AudioDeviceEvent) -> String {
        switch event {
        case let .disconnected(uid): "Device disconnected: \(uid)"
        case let .nominalSampleRateChanged(uid, oldRate, newRate):
            "\(uid) changed from \(Int(oldRate.hertz)) Hz to \(Int(newRate.hertz)) Hz"
        case .defaultInputChanged: "The system default input changed."
        case .defaultOutputChanged: "The system default output changed."
        case .deviceListChanged: "The Core Audio device list changed."
        }
    }
}

private final class RealtimeMeasurementStateRelay: @unchecked Sendable {
    private weak var viewModel: RealtimeMeasurementViewModel?

    @MainActor
    init(viewModel: RealtimeMeasurementViewModel) {
        self.viewModel = viewModel
    }

    func send(_ state: RealtimeMeasurementState) {
        Task { @MainActor in
            self.viewModel?.receive(state: state)
        }
    }
}

private extension RealtimeMeasurementViewModel {
    func receive(state: RealtimeMeasurementState) {
        self.state = state
    }
}
