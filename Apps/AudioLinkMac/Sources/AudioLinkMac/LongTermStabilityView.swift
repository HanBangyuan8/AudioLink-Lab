import AudioLinkCore
import AudioLinkRealtime
import Charts
import SwiftUI

@MainActor
final class LongTermStabilityViewModel: ObservableObject {
    @Published var durationSeconds = 300.0
    @Published var intervalSeconds = 10.0
    @Published var discontinuityThresholdMilliseconds = 2.0
    @Published private(set) var snapshot: LongTermStabilitySnapshot?
    @Published private(set) var report: LongTermStabilityReport?
    @Published private(set) var failure: String?
    @Published private(set) var isBusy = false

    private let controller: any LongTermStabilityControlling
    private weak var realtimeViewModel: RealtimeMeasurementViewModel?
    private var task: Task<Void, Never>?

    init(controller: any LongTermStabilityControlling, realtimeViewModel: RealtimeMeasurementViewModel) {
        self.controller = controller
        self.realtimeViewModel = realtimeViewModel
    }

    deinit { task?.cancel() }

    func start() {
        guard !isBusy, let realtimeViewModel else { return }
        do {
            let baseConfiguration = try realtimeViewModel.makeStabilityBaseConfiguration()
            let plan = LongTermStabilityPlan(
                duration: try DurationSeconds(durationSeconds),
                interval: try DurationSeconds(intervalSeconds),
                discontinuityThresholdMilliseconds: discontinuityThresholdMilliseconds
            )
            failure = nil
            report = nil
            snapshot = nil
            isBusy = true
            let controller = self.controller
            let relay = LongTermStabilitySnapshotRelay(viewModel: self)
            task = Task { [weak self] in
                do {
                    let report = try await controller.execute(plan: plan, baseConfiguration: baseConfiguration) { snapshot in
                        relay.send(snapshot)
                    }
                    guard let self else { return }
                    self.report = report
                    self.snapshot = LongTermStabilitySnapshot(state: .completed, completedEvents: report.observations.count + report.failures.count, totalEvents: plan.scheduledEventCount, observations: report.observations, failures: report.failures, currentDelayMilliseconds: report.observations.last?.delayMilliseconds)
                    self.isBusy = false
                    self.task = nil
                } catch {
                    guard let self else { return }
                    self.failure = error.localizedDescription
                    self.isBusy = false
                    self.task = nil
                }
            }
        } catch { failure = error.localizedDescription }
    }

    func pause() { Task { await controller.pause() } }
    func resume() { Task { try? await controller.resume() } }
    func stop() {
        Task { await controller.cancel() }
        task?.cancel()
        task = nil
        isBusy = false
    }

    fileprivate func receive(snapshot: LongTermStabilitySnapshot) {
        self.snapshot = snapshot
    }
}

private final class LongTermStabilitySnapshotRelay: @unchecked Sendable {
    private weak var viewModel: LongTermStabilityViewModel?

    @MainActor
    init(viewModel: LongTermStabilityViewModel) { self.viewModel = viewModel }

    func send(_ snapshot: LongTermStabilitySnapshot) {
        Task { @MainActor in self.viewModel?.receive(snapshot: snapshot) }
    }
}

struct LongTermStabilityView: View {
    @ObservedObject var viewModel: LongTermStabilityViewModel
    let accentColor: Color
    let motionProfile: VersionedMotionProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Long-term Stability").font(.title2.weight(.semibold))
                    Text("Play a short chirp at a fixed interval, track delay over time, and estimate clock drift. A route change or interruption terminates the series explicitly.")
                        .foregroundStyle(.secondary)
                }
                GroupBox("Test plan") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            numericField("Duration", value: $viewModel.durationSeconds, suffix: "s")
                            numericField("Interval", value: $viewModel.intervalSeconds, suffix: "s")
                            numericField("Jump warning", value: $viewModel.discontinuityThresholdMilliseconds, suffix: "ms")
                        }
                        Text("The displayed event count is a schedule estimate; actual success count depends on device availability and signal quality.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(viewModel.isBusy ? "Stop" : "Start Stability Test") {
                                viewModel.isBusy ? viewModel.stop() : viewModel.start()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accentColor)
                            .disabled(viewModel.isBusy && viewModel.snapshot == nil)
                            if viewModel.isBusy {
                                Button("Pause") { viewModel.pause() }
                                Button("Resume") { viewModel.resume() }
                            }
                        }
                    }
                }
                if let failure = viewModel.failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let snapshot = viewModel.snapshot {
                    progress(snapshot)
                }
                if let report = viewModel.report {
                    reportView(report)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .tint(accentColor)
    }

    private func numericField(_ title: String, value: Binding<Double>, suffix: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(width: 84)
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    private func progress(_ snapshot: LongTermStabilitySnapshot) -> some View {
        GroupBox("Progress") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(snapshot.completedEvents) / \(snapshot.totalEvents) events · \(snapshot.observations.count) successful · \(snapshot.failures.count) failed")
                    .monospacedDigit()
                if let delay = snapshot.currentDelayMilliseconds { Text("Current delay: \(delay.formatted(.number.precision(.fractionLength(3)))) ms").monospacedDigit() }
                if !snapshot.observations.isEmpty {
                    Chart(snapshot.observations) { observation in
                        LineMark(x: .value("Event", observation.eventIndex), y: .value("Delay (ms)", observation.delayMilliseconds))
                            .interpolationMethod(.linear)
                        PointMark(x: .value("Event", observation.eventIndex), y: .value("Delay (ms)", observation.delayMilliseconds))
                    }
                    .frame(height: 180)
                }
            }
        }
    }

    private func reportView(_ report: LongTermStabilityReport) -> some View {
        GroupBox("Stability diagnostics") {
            VStack(alignment: .leading, spacing: 7) {
                metric("Jitter (sample standard deviation)", report.statistics.jitterStandardDeviationMilliseconds)
                metric("Peak-to-peak jitter", report.statistics.peakToPeakJitterMilliseconds)
                if let drift = report.drift {
                    metric("Clock drift", drift.driftPPM)
                    metric("Constant offset", drift.constantOffsetSamples)
                    metric("Fit residual RMS", drift.fit.residualRMSSamples)
                    Text("Drift confidence: \(drift.confidence.formatted(.percent.precision(.fractionLength(1))))")
                    if let warning = drift.nonlinearWarning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if !report.discontinuityEventIndices.isEmpty {
                    Text("Possible discontinuities at events: \(report.discontinuityEventIndices.map(String.init).joined(separator: ", "))")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: Double?) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value.map { $0.formatted(.number.precision(.fractionLength(3))) } ?? "—").monospacedDigit() }
    }
}
