import AudioLinkCore
import AudioLinkDSP
import AudioLinkRealtime
import Combine
import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class RepeatedMeasurementViewModel: ObservableObject {
    @Published private(set) var devices: [AudioDeviceDescription] = []
    @Published var selectedInputID: String?
    @Published var selectedOutputID: String?
    @Published var runCount = 5
    @Published var intervalSeconds = 1.0
    @Published var warmUpRuns = 1
    @Published var discardWarmUp = true
    @Published var stopOnRepeatedFailure = true
    @Published var maximumFailureCount = 3
    @Published var preRollSeconds = 0.25
    @Published var postRollSeconds = 0.5
    @Published var signalKind = SignalKind.logarithmicSweep
    @Published var randomSeedPolicy = RandomSeedPolicy.fixed
    @Published var outlierMethod = OutlierDetectionMethod.medianAbsoluteDeviation
    @Published var outlierThreshold = 3.5
    @Published var includeMarkedOutliers = true
    @Published var acknowledgedSafety = false
    @Published private(set) var snapshot: RepeatedMeasurementSnapshot?
    @Published private(set) var report: RepeatedMeasurementReport?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshingDevices = false

    private let deviceService: any AudioDeviceService
    private let controller: any RepeatedMeasurementControlling
    private let analyzer: StatisticalAnalyzer
    private var task: Task<Void, Never>?

    init(
        deviceService: any AudioDeviceService,
        controller: any RepeatedMeasurementControlling,
        analyzer: StatisticalAnalyzer = .init(),
        loadDevicesImmediately: Bool = true
    ) {
        self.deviceService = deviceService
        self.controller = controller
        self.analyzer = analyzer
        if loadDevicesImmediately {
            Task { [weak self] in await self?.refreshDevices() }
        }
    }

    deinit { task?.cancel() }

    var inputDevices: [AudioDeviceDescription] { devices.filter { $0.inputChannelCount > 0 } }
    var outputDevices: [AudioDeviceDescription] { devices.filter { $0.outputChannelCount > 0 } }
    var selectedInput: AudioDeviceDescription? { inputDevices.first { $0.id == selectedInputID } }
    var selectedOutput: AudioDeviceDescription? { outputDevices.first { $0.id == selectedOutputID } }
    var routeRatesMatch: Bool {
        guard let selectedInput, let selectedOutput else { return false }
        return abs(selectedInput.nominalSampleRate.hertz - selectedOutput.nominalSampleRate.hertz) < 0.5
    }
    var isActive: Bool {
        guard let state = snapshot?.state else { return false }
        switch state {
        case .preparing, .warmingUp, .running, .paused, .cancelling: return true
        case .completed, .failed: return false
        }
    }
    var isPaused: Bool {
        if case .paused = snapshot?.state { return true }
        return false
    }
    var canStart: Bool {
        selectedInput != nil && selectedOutput != nil && routeRatesMatch && acknowledgedSafety && !isActive
    }
    var displayedStatistics: RepeatedMeasurementStatistics? {
        if let report {
            return includeMarkedOutliers
                ? report.statisticsIncludingOutliers
                : report.statisticsExcludingOutliers
        }
        guard let outcomes = snapshot?.outcomes else { return nil }
        return analyzer.analyze(
            outcomes: outcomes,
            includeMarkedOutliers: includeMarkedOutliers,
            method: outlierMethod,
            threshold: outlierThreshold
        )
    }

    func refreshDevices() async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }
        do {
            devices = try await deviceService.devices()
            if selectedInput == nil {
                selectedInputID = devices.first(where: \.isDefaultInput)?.id
                    ?? inputDevices.first?.id
            }
            if selectedOutput == nil {
                selectedOutputID = devices.first(where: \.isDefaultOutput)?.id
                    ?? outputDevices.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = "Audio devices could not be loaded: \(error.localizedDescription)"
        }
    }

    func start() {
        guard !isActive else { return }
        do {
            let plan = try makePlan()
            let configuration = try makeBaseConfiguration()
            snapshot = nil
            report = nil
            errorMessage = nil
            let controller = self.controller
            let relay = RepeatedMeasurementSnapshotRelay(viewModel: self)
            task = Task { [weak self] in
                do {
                    let report = try await controller.execute(
                        plan: plan,
                        baseConfiguration: configuration
                    ) { relay.send($0) }
                    guard let self, !Task.isCancelled else { return }
                    self.report = report
                    self.task = nil
                } catch {
                    guard let self else { return }
                    if let repeated = error as? RepeatedMeasurementError, repeated == .cancelled {
                        self.errorMessage = nil
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                    self.task = nil
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pause() {
        guard isActive, !isPaused else { return }
        Task { await controller.pause() }
    }

    func resume() {
        guard isPaused else { return }
        Task { [weak self] in
            do {
                try await self?.controller.resume()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        guard isActive else { return }
        Task { await controller.cancel() }
    }

    func copyStatistics() {
        guard let statistics = displayedStatistics else { return }
        let text = [
            "AudioLink Lab Repeated Measurement",
            "outcomes: \(statistics.outcomeCount)",
            "successes: \(statistics.successCount)",
            "failures: \(statistics.failureCount)",
            "population: \(statistics.populationCount)",
            "mean_ms: \(format(statistics.meanMilliseconds))",
            "median_ms: \(format(statistics.medianMilliseconds))",
            "jitter_stddev_ms: \(format(statistics.jitterStandardDeviationMilliseconds))",
            "peak_to_peak_jitter_ms: \(format(statistics.peakToPeakJitterMilliseconds))",
            "p90_ms: \(format(statistics.percentile90Milliseconds))",
            "p95_ms: \(format(statistics.percentile95Milliseconds))",
            "p99_ms: \(format(statistics.percentile99Milliseconds))",
            "outliers: \(statistics.outliers.count)",
            "outlier_method: \(statistics.outlierMethod.rawValue)",
            "reliability: \(statistics.reliability.rawValue)"
        ].joined(separator: "\n")
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    func waitForCompletion() async { await task?.value }

    func makePlan() throws -> MeasurementPlan {
        let plan = MeasurementPlan(
            runCount: runCount,
            intervalBetweenRuns: try DurationSeconds(intervalSeconds),
            warmUpRuns: warmUpRuns,
            discardWarmUp: discardWarmUp,
            stopOnRepeatedFailure: stopOnRepeatedFailure,
            maximumFailureCount: maximumFailureCount,
            preRoll: try DurationSeconds(preRollSeconds),
            postRoll: try DurationSeconds(postRollSeconds),
            signalKind: signalKind,
            randomSeedPolicy: randomSeedPolicy,
            outlierMethod: outlierMethod,
            outlierThreshold: outlierThreshold,
            includeMarkedOutliers: includeMarkedOutliers
        )
        try plan.validate()
        return plan
    }

    func makeBaseConfiguration() throws -> RealtimeMeasurementConfiguration {
        guard let input = selectedInput, let output = selectedOutput else {
            throw RepeatedMeasurementError.invalidPlan("Choose both an input and an output device.")
        }
        guard routeRatesMatch else {
            throw RepeatedMeasurementError.invalidPlan("Input and output nominal sample rates must match.")
        }
        let route = AudioRouteConfiguration(
            inputDevice: input,
            outputDevice: output,
            sampleRate: input.nominalSampleRate,
            bufferFrameCount: 512
        )
        let duration = try DurationSeconds(0.5)
        return RealtimeMeasurementConfiguration(
            route: route,
            signal: TestSignalConfiguration(
                kind: signalKind,
                sampleRate: route.sampleRate,
                duration: duration,
                startFrequencyHertz: 80,
                endFrequencyHertz: min(18_000, route.sampleRate.hertz * 0.45),
                amplitude: 0.18,
                fadeIn: try DurationSeconds(0.01),
                fadeOut: try DurationSeconds(0.01),
                deterministicSeed: 0xA0D1_01A5
            ),
            preRoll: try DurationSeconds(preRollSeconds),
            postRoll: try DurationSeconds(postRollSeconds),
            correlation: CorrelationConfiguration(
                method: .automatic,
                normalization: .overlapEnergy,
                searchRange: SampleLagRange(
                    minimum: 0,
                    maximum: Int64(route.sampleRate.hertz.rounded())
                ),
                peakSelection: .absolute,
                sequenceOutput: .searchedRange,
                minimumOverlapRatio: 0.35,
                interpolateSubsample: true
            ),
            preprocessing: PreprocessingConfiguration(removeDCOffset: true)
        )
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.6f", $0) } ?? "unavailable"
    }

    fileprivate func receive(_ snapshot: RepeatedMeasurementSnapshot) {
        self.snapshot = snapshot
    }
}

private final class RepeatedMeasurementSnapshotRelay: @unchecked Sendable {
    private weak var viewModel: RepeatedMeasurementViewModel?

    @MainActor
    init(viewModel: RepeatedMeasurementViewModel) { self.viewModel = viewModel }

    func send(_ snapshot: RepeatedMeasurementSnapshot) {
        Task { @MainActor in self.viewModel?.receive(snapshot) }
    }
}
