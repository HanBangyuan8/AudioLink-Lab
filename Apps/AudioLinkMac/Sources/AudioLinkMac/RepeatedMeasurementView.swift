import AudioLinkCore
import AudioLinkDSP
import AudioLinkRealtime
import SwiftUI

@available(macOS 13.0, *)
struct RepeatedMeasurementView: View {
    @ObservedObject var viewModel: RepeatedMeasurementViewModel
    let accentColor: Color
    let motionProfile: VersionedMotionProfile
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
                .versionedComponentAppear(profile: motionProfile, pageID: "repeated-header", direction: .downward)
            safety
                .interactivePanel(cornerRadius: 12, accentColor: accentColor)
                .versionedComponentAppear(profile: motionProfile, pageID: "repeated-safety", direction: .downward)
            route
                .interactivePanel(cornerRadius: 12, accentColor: accentColor)
                .versionedComponentAppear(profile: motionProfile, pageID: "repeated-route", direction: .downward)
            plan
                .interactivePanel(cornerRadius: 12, accentColor: accentColor)
                .versionedComponentAppear(profile: motionProfile, pageID: "repeated-plan", direction: .downward)
            controls
                .versionedComponentAppear(profile: motionProfile, pageID: "repeated-controls", direction: .downward)
            if let error = viewModel.errorMessage {
                errorCard(error)
                    .interactivePanel(cornerRadius: 12, accentColor: .red)
                    .versionedComponentAppear(profile: motionProfile, pageID: "repeated-error", direction: .downward)
            }
            if let snapshot = viewModel.snapshot {
                progress(snapshot)
                    .interactivePanel(cornerRadius: 12, accentColor: accentColor)
                    .versionedComponentAppear(profile: motionProfile, pageID: "repeated-progress", direction: .downward)
            }
            if let statistics = viewModel.displayedStatistics,
               let outcomes = viewModel.snapshot?.outcomes ?? viewModel.report?.outcomes {
                results(statistics: statistics, outcomes: outcomes)
                    .interactivePanel(cornerRadius: 12, accentColor: accentColor)
                    .versionedComponentAppear(
                        profile: motionProfile,
                        pageID: "repeated-results",
                        direction: .downward,
                        isChart: true
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                headerCopy
                Spacer(minLength: 18)
                refreshButton
            }
            VStack(alignment: .leading, spacing: 12) {
                headerCopy
                refreshButton
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Repeated Real-time Measurement")
                .font(.title2.weight(.semibold))
            Text("Run one frozen audio configuration repeatedly, preserve every outcome, and quantify latency variation without silently removing outliers.")
                .foregroundStyle(.secondary)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refreshDevices() }
        } label: {
            Label(viewModel.isRefreshingDevices ? "Refreshing…" : "Refresh Devices", systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isRefreshingDevices || viewModel.isActive)
        .controlButtonHover(accentColor: accentColor)
    }

    private var safety: some View {
        GroupBox {
            Toggle(
                "I checked playback volume, routing, and feedback risk. AudioLink does not monitor the input to the output.",
                isOn: $viewModel.acknowledgedSafety
            )
        } label: {
            Label("Safety", systemImage: "exclamationmark.shield")
        }
    }

    private var route: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                devicePicker("Output device", selection: $viewModel.selectedOutputID, devices: viewModel.outputDevices)
                devicePicker("Input device", selection: $viewModel.selectedInputID, devices: viewModel.inputDevices)
                if !viewModel.routeRatesMatch,
                   viewModel.selectedInput != nil,
                   viewModel.selectedOutput != nil {
                    Label("Input and output nominal sample rates must match. The plan will not mix route conditions.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        } label: {
            Label("Frozen Audio Route", systemImage: "arrow.triangle.branch")
        }
        .disabled(viewModel.isActive)
    }

    private func devicePicker(
        _ title: String,
        selection: Binding<String?>,
        devices: [AudioDeviceDescription]
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).frame(width: 120, alignment: .leading)
                routePicker(title, selection: selection, devices: devices)
                    .frame(minWidth: 300, maxWidth: 520)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                routePicker(title, selection: selection, devices: devices)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func routePicker(
        _ title: String,
        selection: Binding<String?>,
        devices: [AudioDeviceDescription]
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Choose a device").tag(String?.none)
            ForEach(devices) { device in
                Text("\(device.name) · \(Int(device.nominalSampleRate.hertz)) Hz")
                    .tag(Optional(device.id))
                }
        }
        .labelsHidden()
    }

    private var plan: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        primaryPlanControls
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        primaryPlanControls
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        signalPlanControls
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        signalPlanControls
                    }
                }
                DisclosureGroup("Advanced plan and outlier settings", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Stop after repeated failures", isOn: $viewModel.stopOnRepeatedFailure)
                            Stepper("Maximum consecutive failures: \(viewModel.maximumFailureCount)", value: $viewModel.maximumFailureCount, in: 1...20)
                                .disabled(!viewModel.stopOnRepeatedFailure)
                        }
                        HStack {
                            numberField("Pre-roll", value: $viewModel.preRollSeconds, suffix: "s")
                            numberField("Post-roll", value: $viewModel.postRollSeconds, suffix: "s")
                        }
                        HStack {
                            Picker("Seed policy", selection: $viewModel.randomSeedPolicy) {
                                ForEach(RandomSeedPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Outlier method", selection: $viewModel.outlierMethod) {
                                Text("MAD-based").tag(OutlierDetectionMethod.medianAbsoluteDeviation)
                                Text("IQR-based").tag(OutlierDetectionMethod.interquartileRange)
                            }
                            numberField("Threshold", value: $viewModel.outlierThreshold, suffix: viewModel.outlierMethod == .medianAbsoluteDeviation ? "scaled MAD" : "× IQR")
                        }
                        Toggle("Include marked outliers in displayed statistics", isOn: $viewModel.includeMarkedOutliers)
                        Text("Outliers are always retained and shown. This switch only changes the aggregate population.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        } label: {
            Label("Measurement Plan", systemImage: "repeat")
        }
        .disabled(viewModel.isActive)
    }

    @ViewBuilder
    private var primaryPlanControls: some View {
        Picker("Run count", selection: $viewModel.runCount) {
            ForEach([5, 20, 100], id: \.self) { Text("\($0) runs").tag($0) }
        }
        .frame(width: 180)
        Stepper("Warm-up: \(viewModel.warmUpRuns)", value: $viewModel.warmUpRuns, in: 0...20)
        Toggle("Discard warm-up from statistics", isOn: $viewModel.discardWarmUp)
    }

    @ViewBuilder
    private var signalPlanControls: some View {
        Picker("Signal", selection: $viewModel.signalKind) {
            ForEach(SignalKind.allCases, id: \.self) { Text(signalName($0)).tag($0) }
        }
        .frame(width: 260)
        numberField("Interval", value: $viewModel.intervalSeconds, suffix: "s")
    }

    private func numberField(_ title: String, value: Binding<Double>, suffix: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 78)
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if !viewModel.isActive {
                Button { viewModel.start() } label: {
                    Label("Start Repeated Measurement", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(!viewModel.canStart)
                .keyboardShortcut(.return, modifiers: [.command])
                .controlButtonHover(accentColor: accentColor)
            } else if viewModel.isPaused {
                Button { viewModel.resume() } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .controlButtonHover(accentColor: accentColor)
            } else {
                Button { viewModel.pause() } label: { Label("Pause", systemImage: "pause.fill") }
            }
            if viewModel.isActive {
                Button(role: .destructive) { viewModel.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Spacer()
        }
    }

    private func progress(_ snapshot: RepeatedMeasurementSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(stateName(snapshot.state), systemImage: stateIcon(snapshot.state))
                        .font(.headline)
                    Spacer()
                    Text("\(snapshot.completedSteps) / \(snapshot.totalScheduledSteps) steps")
                        .monospacedDigit()
                }
                ProgressView(value: Double(snapshot.completedSteps), total: Double(max(1, snapshot.totalScheduledSteps)))
                    .tint(accentColor)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 118), spacing: 12)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    progressMetric("Completed", snapshot.completedSteps)
                    progressMetric("Successful", snapshot.successCount)
                    progressMetric("Failed", snapshot.failureCount)
                    progressMetric("Remaining", snapshot.remainingSteps)
                    if let delay = snapshot.currentDelayMilliseconds {
                        VStack(alignment: .leading) {
                            Text("Latest delay").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.3f ms", delay)).monospacedDigit()
                        }
                    }
                }
                Text("Remaining steps are shown instead of a precise ETA because permission, route, capture, and analysis time can vary per run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("Plan Progress", systemImage: "list.number")
        }
    }

    private func progressMetric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.headline).monospacedDigit()
        }
    }

    private func results(
        statistics: RepeatedMeasurementStatistics,
        outcomes: [RunOutcome]
    ) -> some View {
        let plots = RepeatedMeasurementPlotData(outcomes: outcomes, statistics: statistics)
        return GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("\(statistics.reliability.rawValue.capitalized) statistical reliability", systemImage: "chart.bar.doc.horizontal")
                        .font(.headline)
                    Spacer()
                    Button("Copy Statistics") { viewModel.copyStatistics() }
                }
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(
                                minimum: AudioLinkLayoutMetrics.statisticCardMinimumWidth,
                                maximum: 260
                            ),
                            spacing: 10
                        )
                    ],
                    spacing: 10
                ) {
                    statisticText("Population", "\(statistics.populationCount) selected / \(statistics.outcomeCount) outcomes")
                    statistic("Minimum", statistics.minimumMilliseconds, unit: "ms")
                    statistic("Maximum", statistics.maximumMilliseconds, unit: "ms")
                    statistic("Mean", statistics.meanMilliseconds, unit: "ms")
                    statistic("Median / P50", statistics.medianMilliseconds, unit: "ms")
                    statistic("Variance", statistics.varianceMillisecondsSquared, unit: "ms²")
                    statistic("Jitter (sample SD)", statistics.jitterStandardDeviationMilliseconds, unit: "ms")
                    statistic("Peak-to-peak jitter", statistics.peakToPeakJitterMilliseconds, unit: "ms")
                    statistic("P90", statistics.percentile90Milliseconds, unit: "ms")
                    statistic("P95", statistics.percentile95Milliseconds, unit: "ms")
                    statistic("P99", statistics.percentile99Milliseconds, unit: "ms")
                    statistic("MAD", statistics.medianAbsoluteDeviationMilliseconds, unit: "ms")
                    statistic("IQR", statistics.interquartileRangeMilliseconds, unit: "ms")
                }
                Text(qualityDistribution(statistics.qualityDistribution))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let interval = statistics.confidenceInterval {
                    Text(String(format: "95%% mean confidence interval: %.3f…%.3f ms (%@)", interval.lowerBoundMilliseconds, interval.upperBoundMilliseconds, interval.method))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("A confidence interval is not reported until at least two successful observations exist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Label(
                    "\(statistics.outliers.count) marked outlier(s) using \(outlierName(statistics.outlierMethod)) at threshold \(statistics.outlierThreshold, specifier: "%.2f"). Raw runs are retained.",
                    systemImage: statistics.outliers.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.callout)
                RepeatedMeasurementCharts(data: plots, accentColor: accentColor)
            }
        } label: {
            Label("Live Statistics and Distribution", systemImage: "chart.xyaxis.line")
        }
    }

    private func statistic(_ title: String, _ value: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.3f %@", $0, unit) } ?? "—")
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statisticText(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func qualityDistribution(_ distribution: QualityLevelDistribution) -> String {
        "Quality · Excellent \(distribution.excellent) · Good \(distribution.good) · Questionable \(distribution.questionable) · Poor \(distribution.poor) · Invalid \(distribution.invalid)"
    }

    private func errorCard(_ message: String) -> some View {
        GroupBox {
            Label(message, systemImage: "exclamationmark.octagon")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signalName(_ signal: SignalKind) -> String {
        switch signal {
        case .logarithmicSweep: "Logarithmic sweep"
        case .linearSweep: "Linear sweep"
        case .shortChirp: "Short chirp"
        case .maximumLengthSequence: "Maximum Length Sequence"
        case .impulse: "Impulse"
        case .silence: "Silence (diagnostic)"
        case .bandLimitedNoise: "Band-limited noise"
        }
    }

    private func stateName(_ state: RepeatedMeasurementState) -> String {
        switch state {
        case .preparing: "Preparing and validating route"
        case let .warmingUp(current, total): "Warm-up \(current) of \(total)"
        case let .running(current, total): "Run \(current) of \(total)"
        case .paused: "Paused · device will be revalidated before resuming"
        case .cancelling: "Cancelling safely"
        case .completed: "Plan completed"
        case .failed: "Plan stopped"
        }
    }

    private func stateIcon(_ state: RepeatedMeasurementState) -> String {
        switch state {
        case .completed: "checkmark.seal"
        case .failed: "xmark.octagon"
        case .paused: "pause.circle"
        case .cancelling: "stop.circle"
        default: "waveform"
        }
    }

    private func outlierName(_ method: OutlierDetectionMethod) -> String {
        method == .medianAbsoluteDeviation ? "scaled MAD" : "IQR fences"
    }
}

@available(macOS 13.0, *)
private struct RepeatedMeasurementCharts: View {
    let data: RepeatedMeasurementPlotData
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            chart("Delay over run index", subtitle: "Failed runs are ×; marked outliers are ringed.") {
                DelayTrendCanvas(data: data, accentColor: accentColor)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    histogramChart
                        .frame(minWidth: AudioLinkLayoutMetrics.pairedChartMinimumWidth)
                    boxPlotChart
                        .frame(minWidth: AudioLinkLayoutMetrics.pairedChartMinimumWidth)
                }
                VStack(alignment: .leading, spacing: 14) {
                    histogramChart
                    boxPlotChart
                }
            }
            chart("Quality over time", subtitle: "Excellent → invalid; failed runs are crossed.") {
                QualityTimelineCanvas(data: data)
            }
        }
    }

    private var histogramChart: some View {
        chart("Histogram", subtitle: "Successful delay distribution") {
            HistogramCanvas(data: data, accentColor: accentColor)
        }
    }

    private var boxPlotChart: some View {
        chart("Box plot", subtitle: "Min, Q1, median, Q3, max") {
            BoxPlotCanvas(data: data, accentColor: accentColor)
        }
    }

    private func chart<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            content().frame(height: 150)
                .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(macOS 13.0, *)
private struct DelayTrendCanvas: View {
    let data: RepeatedMeasurementPlotData
    let accentColor: Color

    var body: some View {
        Canvas { context, size in
            let padding: CGFloat = 14
            let values = data.points.compactMap(\.delayMilliseconds)
            let minimum = values.min() ?? 0
            let maximum = values.max() ?? 1
            let span = max(0.000_001, maximum - minimum)
            let denominator = max(1, data.points.count - 1)
            var path = Path()
            var started = false
            for (offset, point) in data.points.enumerated() {
                let x = padding + CGFloat(offset) / CGFloat(denominator) * (size.width - padding * 2)
                if let value = point.delayMilliseconds {
                    let y = size.height - padding - CGFloat((value - minimum) / span) * (size.height - padding * 2)
                    if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
                    let rect = CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
                    context.fill(Path(ellipseIn: rect), with: .color(point.isWarmUp ? .secondary : accentColor))
                    if point.isOutlier {
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.orange), lineWidth: 2)
                    }
                } else {
                    var cross = Path()
                    cross.move(to: CGPoint(x: x - 4, y: size.height / 2 - 4))
                    cross.addLine(to: CGPoint(x: x + 4, y: size.height / 2 + 4))
                    cross.move(to: CGPoint(x: x + 4, y: size.height / 2 - 4))
                    cross.addLine(to: CGPoint(x: x - 4, y: size.height / 2 + 4))
                    context.stroke(cross, with: .color(.red), lineWidth: 1.5)
                }
            }
            context.stroke(path, with: .color(accentColor.opacity(0.65)), lineWidth: 1.25)
        }
    }
}

@available(macOS 13.0, *)
private struct HistogramCanvas: View {
    let data: RepeatedMeasurementPlotData
    let accentColor: Color

    var body: some View {
        Canvas { context, size in
            let maximum = max(1, data.histogram.map(\.count).max() ?? 1)
            let width = size.width / CGFloat(max(1, data.histogram.count))
            for (index, bin) in data.histogram.enumerated() {
                let height = CGFloat(bin.count) / CGFloat(maximum) * max(0, size.height - 12)
                let rect = CGRect(x: CGFloat(index) * width + 1, y: size.height - height, width: max(1, width - 2), height: height)
                context.fill(Path(rect), with: .color(accentColor.opacity(0.75)))
            }
        }
    }
}

@available(macOS 13.0, *)
private struct BoxPlotCanvas: View {
    let data: RepeatedMeasurementPlotData
    let accentColor: Color

    var body: some View {
        Canvas { context, size in
            guard let box = data.box else { return }
            let span = max(0.000_001, box.maximum - box.minimum)
            func x(_ value: Double) -> CGFloat { 16 + CGFloat((value - box.minimum) / span) * (size.width - 32) }
            let y = size.height / 2
            var whisker = Path()
            whisker.move(to: CGPoint(x: x(box.minimum), y: y))
            whisker.addLine(to: CGPoint(x: x(box.maximum), y: y))
            context.stroke(whisker, with: .color(.secondary), lineWidth: 2)
            let rect = CGRect(x: x(box.q1), y: y - 25, width: max(1, x(box.q3) - x(box.q1)), height: 50)
            context.fill(Path(rect), with: .color(accentColor.opacity(0.22)))
            context.stroke(Path(rect), with: .color(accentColor), lineWidth: 2)
            var median = Path()
            median.move(to: CGPoint(x: x(box.median), y: y - 25))
            median.addLine(to: CGPoint(x: x(box.median), y: y + 25))
            context.stroke(median, with: .color(accentColor), lineWidth: 2)
        }
    }
}

@available(macOS 13.0, *)
private struct QualityTimelineCanvas: View {
    let data: RepeatedMeasurementPlotData

    var body: some View {
        Canvas { context, size in
            let width = size.width / CGFloat(max(1, data.points.count))
            for (index, point) in data.points.enumerated() {
                let rect = CGRect(x: CGFloat(index) * width + 1, y: 12, width: max(2, width - 2), height: size.height - 24)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color(point.quality).opacity(point.isWarmUp ? 0.4 : 0.85)))
                if point.failed {
                    var cross = Path()
                    cross.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    cross.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    cross.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                    cross.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    context.stroke(cross, with: .color(.primary), lineWidth: 1)
                }
            }
        }
    }

    private func color(_ quality: MeasurementQualityLevel?) -> Color {
        switch quality {
        case .excellent: .green
        case .good: .blue
        case .questionable: .orange
        case .poor: .red
        case .invalid, .none: .gray
        }
    }
}
