import AppKit
import AudioLinkCore
import AudioLinkReporting
import AudioLinkStorage
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 13.0, *)
struct MeasurementHistoryView: View {
    @ObservedObject var viewModel: MeasurementHistoryViewModel
    let accentColor: Color
    let motionProfile: VersionedMotionProfile

    @State private var confirmsClear = false
    @State private var confirmsDeleteSelection = false
    @State private var exportStatus: String?
    @State private var showingReportExport = false

    init(
        viewModel: MeasurementHistoryViewModel,
        accentColor: Color,
        motionProfile: VersionedMotionProfile = .current
    ) {
        self.viewModel = viewModel
        self.accentColor = accentColor
        self.motionProfile = motionProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
                .versionedComponentAppear(profile: motionProfile, pageID: "history-header", direction: .downward)
            filters
                .versionedComponentAppear(profile: motionProfile, pageID: "history-filters", direction: .downward)
            actionBar
                .versionedComponentAppear(profile: motionProfile, pageID: "history-actions", direction: .downward)
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }
            GeometryReader { geometry in
                historyPanels(availableWidth: geometry.size.width)
                    .versionedComponentAppear(
                        profile: motionProfile,
                        pageID: "history-panels",
                        direction: .downward
                    )
            }
        }
        .task { await viewModel.reload() }
        .alert("Clear all measurement history?", isPresented: $confirmsClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                Task { await viewModel.clearAll() }
            }
        } message: {
            Text("This removes every saved session and run. Source audio outside AudioLink is never changed.")
        }
        .alert("Delete selected runs?", isPresented: $confirmsDeleteSelection) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Runs", role: .destructive) {
                Task { await viewModel.deleteSelected() }
            }
        }
        .sheet(isPresented: comparisonPresented) {
            if let comparison = viewModel.comparison {
                HistoryComparisonView(comparison: comparison) {
                    viewModel.clearComparison()
                }
                .frame(minWidth: 820, minHeight: 520)
            }
        }
        .sheet(isPresented: $showingReportExport) {
            ReportExportSheet(title: "Export Measurement Report") { format, privacy, chapters, destination in
                try await viewModel.exportSelectedReport(format: format, privacy: privacy, chapters: chapters, destination: destination)
            } onDismiss: {
                showingReportExport = false
            }
        }
    }

    @ViewBuilder
    private func historyPanels(availableWidth: CGFloat) -> some View {
        if AudioLinkLayoutMetrics.historyUsesSplitLayout(availableWidth: availableWidth) {
            HSplitView {
                runList
                    .frame(minWidth: 520, idealWidth: 650)
                detailPanel
                    .frame(minWidth: 340, idealWidth: 460)
            }
        } else {
            VSplitView {
                runList
                    .frame(minHeight: 230, idealHeight: 310)
                detailPanel
                    .frame(minHeight: 180, idealHeight: 250)
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                historyTitle
                Spacer(minLength: 18)
                repositorySummary
            }
            VStack(alignment: .leading, spacing: 7) {
                historyTitle
                repositorySummary
            }
        }
    }

    private var historyTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("History").font(.largeTitle.bold())
            Text("Private, local measurement sessions and runs")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var repositorySummary: some View {
        if let info = viewModel.repositoryInfo {
            Text("\(info.runCount) runs · schema v\(info.schemaVersion) · \(ByteCountFormatter.string(fromByteCount: info.databaseSizeBytes, countStyle: .file))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                filterControls
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    searchField
                    qualityPicker
                }
                HStack(spacing: 10) {
                    deviceField
                    measurementTypePicker
                    applyFiltersButton
                    clearFiltersButton
                }
            }
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        searchField
        qualityPicker
        deviceField
        measurementTypePicker
        applyFiltersButton
        clearFiltersButton
    }

    private var searchField: some View {
        TextField("Search file names or notes", text: $viewModel.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220)
            .onSubmit { Task { await viewModel.reload() } }
    }

    private var qualityPicker: some View {
        Picker("Quality", selection: $viewModel.qualityFilter) {
            Text("All quality").tag("all")
            ForEach(MeasurementQualityLevel.allCases, id: \.rawValue) { level in
                Text(level.rawValue.capitalized).tag(level.rawValue)
            }
        }
        .frame(width: 150)
    }

    private var deviceField: some View {
        TextField("Device", text: $viewModel.deviceSearchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            .onSubmit { Task { await viewModel.reload() } }
    }

    private var measurementTypePicker: some View {
        Picker("Measurement type", selection: $viewModel.measurementTypeFilter) {
            Text("All types").tag("all")
            ForEach(StoredMeasurementType.allCases, id: \.rawValue) { type in
                Text(measurementTypeTitle(type)).tag(type.rawValue)
            }
        }
        .frame(width: 150)
    }

    private var applyFiltersButton: some View {
        Button("Apply Filters") { Task { await viewModel.reload() } }
            .buttonStyle(.borderedProminent)
    }

    private var clearFiltersButton: some View {
        Button {
            viewModel.searchText = ""
            viewModel.deviceSearchText = ""
            viewModel.qualityFilter = "all"
            viewModel.measurementTypeFilter = "all"
            Task { await viewModel.reload() }
        } label: {
            Image(systemName: "xmark.circle")
        }
        .help("Clear history filters")
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Text("\(viewModel.selectedRunIDs.count) selected")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Compare") { Task { await viewModel.compareSelected() } }
                .disabled(viewModel.selectedRunIDs.count < 2)
            Button("Export Report…") { showingReportExport = true }
                .disabled(viewModel.selectedRunIDs.isEmpty)
            Button("Delete Selected", role: .destructive) { confirmsDeleteSelection = true }
                .disabled(viewModel.selectedRunIDs.isEmpty)
            Spacer()
            if let exportStatus { Text(exportStatus).font(.caption).foregroundStyle(.secondary) }
            Button("Clear History…", role: .destructive) { confirmsClear = true }
                .disabled(viewModel.totalCount == 0)
        }
        .buttonStyle(.bordered)
    }

    private var runList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Runs").font(.headline)
                Spacer()
                Text("\(viewModel.runs.count) of \(viewModel.totalCount)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            if viewModel.runs.isEmpty, !viewModel.isLoading {
                historyPlaceholder(
                    title: "No History",
                    symbol: "clock.arrow.circlepath",
                    description: "Completed measurements saved under the selected privacy policy appear here."
                )
            } else {
                List(viewModel.runs) { run in
                    HistoryRunRow(
                        run: run,
                        isSelected: viewModel.selectedRunIDs.contains(run.id),
                        accentColor: accentColor,
                        toggleSelection: { toggleSelection(run.id) },
                        open: { Task { await viewModel.openRun(id: run.id) } },
                        delete: { Task { await viewModel.deleteRun(id: run.id) } }
                    )
                    .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
            if viewModel.isLoading {
                ProgressView("Loading history…").padding(9)
            } else if viewModel.hasMore {
                Button("Load More") { Task { await viewModel.loadMore() } }
                    .padding(9)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.18)) }
        .interactivePanel(cornerRadius: 12, accentColor: accentColor)
    }

    private var detailPanel: some View {
        Group {
            if let run = viewModel.selectedRun, let session = viewModel.selectedSession {
                HistoryRunDetailView(
                    session: session,
                    run: run,
                    saveMetadata: { name, notes in
                        Task { await viewModel.updateSelectedSession(name: name, notes: notes) }
                    }
                )
            } else {
                historyPlaceholder(
                    title: "Select a Run",
                    symbol: "doc.text.magnifyingglass",
                    description: "Open a saved run to inspect its result, privacy policy, processing, and chart availability."
                )
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.18)) }
        .interactivePanel(cornerRadius: 12, accentColor: accentColor)
    }

    private var comparisonPresented: Binding<Bool> {
        Binding(
            get: { viewModel.comparison != nil },
            set: { if !$0 { viewModel.clearComparison() } }
        )
    }

    private func historyPlaceholder(title: String, symbol: String, description: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleSelection(_ id: UUID) {
        if viewModel.selectedRunIDs.contains(id) {
            viewModel.selectedRunIDs.remove(id)
        } else {
            viewModel.selectedRunIDs.insert(id)
        }
    }

    private func measurementTypeTitle(_ type: StoredMeasurementType) -> String {
        switch type {
        case .offlineFile: "File analysis"
        case .liveAudio: "Live audio"
        case .networkLink: "Network link"
        }
    }
}

@available(macOS 13.0, *)
private struct HistoryRunRow: View {
    let run: MeasurementHistoryRunSummary
    let isSelected: Bool
    let accentColor: Color
    let toggleSelection: () -> Void
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect run" : "Select run")
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(run.referenceFileName).lineLimit(1)
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                        Text(run.recordingFileName).lineLimit(1)
                        Spacer()
                        Text(run.delayMilliseconds.map { String(format: "%.3f ms", $0) } ?? "Unavailable")
                            .font(.headline.monospacedDigit())
                    }
                    HStack {
                        Label(run.qualityLevel.rawValue.capitalized, systemImage: qualitySymbol(run.qualityLevel))
                        Text(run.createdAt.formatted(date: .abbreviated, time: .standard))
                        Text("\(run.sampleRateHertz, specifier: "%.0f") Hz")
                        Text("\(run.confidence, format: .percent.precision(.fractionLength(0)))")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .controlButtonHover(accentColor: accentColor)
        }
        .contextMenu {
            Button("Open", action: open)
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func qualitySymbol(_ level: MeasurementQualityLevel) -> String {
        switch level {
        case .excellent: "checkmark.seal.fill"
        case .good: "checkmark.circle.fill"
        case .questionable: "questionmark.diamond.fill"
        case .poor: "exclamationmark.triangle.fill"
        case .invalid: "xmark.octagon.fill"
        }
    }
}

@available(macOS 13.0, *)
private struct HistoryRunDetailView: View {
    let session: MeasurementHistorySession
    let run: MeasurementHistoryRun
    let saveMetadata: (String, String) -> Void

    @State private var name: String
    @State private var notes: String

    init(
        session: MeasurementHistorySession,
        run: MeasurementHistoryRun,
        saveMetadata: @escaping (String, String) -> Void
    ) {
        self.session = session
        self.run = run
        self.saveMetadata = saveMetadata
        _name = State(initialValue: session.name)
        _notes = State(initialValue: session.notes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text("Run Detail").font(.title2.bold())
                        detailMetric("Delay", run.delayEstimate.map { String(format: "%.3f ms", $0.fractionalMilliseconds) } ?? "Unavailable")
                detailMetric("Quality", "\(run.quality.level.rawValue.capitalized) · \(String(format: "%.0f%%", run.quality.confidence.value * 100))")
                detailMetric("Sample rate", String(format: "%.0f Hz", run.referenceFile.format.sampleRate.hertz))
                detailMetric("Application", session.appVersion)
                detailMetric("Algorithm", session.algorithmVersion)
                detailMetric("Privacy", session.savePolicy.userTitle)

                if let aggregate = session.repeatedStatistics {
                    Divider()
                    Text("Repeated session aggregate").font(.headline)
                    detailMetric("Measured outcomes", "\(aggregate.outcomeCount)")
                    detailMetric("Success / failure", "\(aggregate.successCount) / \(aggregate.failureCount)")
                    detailMetric("Selected population", "\(aggregate.populationCount)")
                    detailMetric("Mean", aggregate.meanMilliseconds.map { String(format: "%.3f ms", $0) } ?? "Unavailable")
                    detailMetric("Median / P50", aggregate.medianMilliseconds.map { String(format: "%.3f ms", $0) } ?? "Unavailable")
                    detailMetric("Jitter (sample SD)", aggregate.jitterStandardDeviationMilliseconds.map { String(format: "%.3f ms", $0) } ?? "Unavailable")
                    detailMetric(
                        "P95 / P99",
                        "\(aggregate.percentile95Milliseconds.map { String(format: "%.6f", $0) } ?? "Unavailable") / \(aggregate.percentile99Milliseconds.map { String(format: "%.6f", $0) } ?? "Unavailable") ms"
                    )
                    detailMetric("Outliers", "\(aggregate.outliers.count) · \(aggregate.outlierMethod.rawValue) @ \(aggregate.outlierThreshold)")
                    detailMetric("Reliability", aggregate.reliability.rawValue.capitalized)
                    Text("Raw runs are retained. The aggregate \(aggregate.includesMarkedOutliers ? "includes" : "excludes") marked outliers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                Text("Chart reconstruction").font(.headline)
                chartAvailability(
                    title: "Correlation and peak detail",
                    available: run.chartCache.correlationSequenceAvailable,
                    detail: run.chartCache.correlationSequenceAvailable
                        ? "\(run.chartCache.correlationSampleCount) signed correlation samples retained."
                        : "The correlation sequence was not retained."
                )
                chartAvailability(
                    title: "Waveforms",
                    available: run.chartCache.waveformAvailable,
                    detail: run.chartCache.waveformAvailable
                        ? "Audio copies are available in the application container."
                        : run.chartCache.waveformUnavailableReason ?? "Raw audio was not retained."
                )

                Divider()
                Text("Processing").font(.headline)
                if run.processingSteps.isEmpty {
                    Text("No preprocessing transformations were recorded.").foregroundStyle(.secondary)
                } else {
                    ForEach(run.processingSteps) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(step.role.rawValue.capitalized): \(step.summary)")
                            Text("\(step.inputFrameCount) → \(step.outputFrameCount) frames")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                Text("Session metadata").font(.headline)
                TextField("Session name", text: $name)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
                Button("Save Name and Notes") { saveMetadata(name, notes) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .id(run.id)
    }

    private func detailMetric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func chartAvailability(title: String, available: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(available ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@available(macOS 13.0, *)
private struct HistoryComparisonView: View {
    let comparison: MeasurementRunComparison
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Compare Runs").font(.title2.bold())
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            Text("Differences are relative to the first selected run.")
                .foregroundStyle(.secondary)
            Table(comparison.entries) {
                TableColumn("Run") { entry in
                    Text(entry.id == comparison.baselineRunID ? "Baseline" : entry.summary.createdAt.formatted())
                }
                TableColumn("Δ Delay") { entry in
                    Text(entry.delayDifferenceMilliseconds.map { String(format: "%+.4f ms", $0) } ?? "Unavailable")
                        .monospacedDigit()
                }
                TableColumn("Δ Quality") { entry in
                    Text(entry.qualityLevelDifference)
                }
                TableColumn("Δ Confidence") { entry in
                    Text(String(format: "%+.1f%%", entry.confidenceDifference * 100)).monospacedDigit()
                }
                TableColumn("Δ Sample Rate") { entry in
                    Text(String(format: "%+.0f Hz", entry.sampleRateDifferenceHertz)).monospacedDigit()
                }
                TableColumn("Configuration") { entry in
                    Text(entry.configurationDifferences.isEmpty ? "Same" : entry.configurationDifferences.joined(separator: ", "))
                }
                TableColumn("Processing / Devices") { entry in
                    Text(
                        [
                            entry.preprocessingDifferences.isEmpty ? nil : "Processing differs",
                            entry.deviceDifference ? "Devices differ" : nil
                        ].compactMap { $0 }.joined(separator: " · ").isEmpty
                            ? "Same"
                            : [
                                entry.preprocessingDifferences.isEmpty ? nil : "Processing differs",
                                entry.deviceDifference ? "Devices differ" : nil
                            ].compactMap { $0 }.joined(separator: " · ")
                    )
                }
            }
        }
        .padding(20)
    }
}
