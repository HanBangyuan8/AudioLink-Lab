import AppKit
import AudioLinkCore
import AudioLinkDSP
import AudioLinkReporting
import SwiftUI

@available(macOS 13.0, *)
private enum MeasurementReviewSection: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case waveforms = "Waveforms"
    case correlation = "Correlation"
    case diagnostics = "Diagnostics"
    case processingLog = "Processing Log"

    var id: String { rawValue }
}

@available(macOS 13.0, *)
struct MeasurementResultReview: View {
    let analysis: NewMeasurementAnalysis
    let accentColor: Color
    let motionProfile: VersionedMotionProfile

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var visualization: MeasurementVisualizationViewModel
    @State private var selectedSection = MeasurementReviewSection.summary
    @State private var sectionNavigationDirection: PageNavigationDirection = .downward
    @State private var copiedResult = false
    @State private var showingReportExport = false

    init(
        analysis: NewMeasurementAnalysis,
        accentColor: Color,
        motionProfile: VersionedMotionProfile = .current
    ) {
        self.analysis = analysis
        self.accentColor = accentColor
        self.motionProfile = motionProfile
        _visualization = StateObject(
            wrappedValue: MeasurementVisualizationViewModel(analysis: analysis)
        )
    }

    private var sectionAnimation: Animation? {
        reduceMotion || motionProfile.disablesMotion ? nil : motionProfile.pageSwitchAnimation
    }

    private var sectionSelection: Binding<MeasurementReviewSection> {
        Binding(
            get: { selectedSection },
            set: { nextSection in
                guard nextSection != selectedSection else { return }
                let sections = MeasurementReviewSection.allCases
                let currentIndex = sections.firstIndex(of: selectedSection) ?? 0
                let nextIndex = sections.firstIndex(of: nextSection) ?? currentIndex
                sectionNavigationDirection = nextIndex >= currentIndex ? .downward : .upward
                withAnimation(sectionAnimation) {
                    selectedSection = nextSection
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            reviewHeader

            Picker("Result section", selection: sectionSelection) {
                ForEach(MeasurementReviewSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Measurement result section")

            selectedSectionContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(selectedSection.id)
                .transition(
                    sectionNavigationDirection.transition(
                        reduceMotion: reduceMotion,
                        intensity: motionProfile.intensity
                    )
                )
                .versionedPageSwitchMotion(
                    profile: motionProfile,
                    pageID: selectedSection.id,
                    direction: sectionNavigationDirection
                )

            if let error = visualization.preparationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accentColor.opacity(0.38), lineWidth: 1.5)
        }
        .interactivePanel(cornerRadius: 16, accentColor: accentColor)
        .task {
            visualization.prepare(pixelWidth: 1_400)
        }
        .sheet(isPresented: $showingReportExport) {
            ReportExportSheet(title: "Export Measurement Report") { format, privacy, chapters, destination in
                let document = AppReportExportAdapters.document(for: analysis, privacy: privacy, chapters: chapters)
                return try await ReportExporter.write(document: document, format: format, to: destination)
            } onDismiss: {
                showingReportExport = false
            }
        }
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .summary:
            summaryView
        case .waveforms:
            waveformView
        case .correlation:
            correlationView
        case .diagnostics:
            diagnosticsView
        case .processingLog:
            processingLogView
        }
    }

    private var reviewHeader: some View {
        let result = analysis.presentation
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                reviewHeaderCopy(result)
                Spacer(minLength: 18)
                headerActions(result)
            }
            VStack(alignment: .leading, spacing: 10) {
                reviewHeaderCopy(result)
                headerActions(result)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func reviewHeaderCopy(_ result: NewMeasurementResultPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Review Result", systemImage: qualitySymbol(result.qualityLevel))
                .font(.title2.bold())
            Text("\(qualityTitle(result.qualityLevel)) · \(result.confidence, format: .percent.precision(.fractionLength(0))) confidence")
                .font(.headline)
            Text(result.summary)
                .foregroundStyle(.secondary)
        }
    }

    private func copyResultButton(_ result: NewMeasurementResultPresentation) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.structuredText, forType: .string)
            copiedResult = true
        } label: {
            Label(copiedResult ? "Copied" : "Copy Result", systemImage: copiedResult ? "checkmark" : "doc.on.doc")
        }
        .accessibilityLabel("Copy structured measurement result")
        .controlButtonHover(accentColor: accentColor)
    }

    private func headerActions(_ result: NewMeasurementResultPresentation) -> some View {
        HStack(spacing: 8) {
            copyResultButton(result)
            Button {
                showingReportExport = true
            } label: {
                Label("Export Report", systemImage: "doc.richtext")
            }
            .accessibilityLabel("Export measurement report")
            .controlButtonHover(accentColor: accentColor)
        }
    }

    private var summaryView: some View {
        let result = analysis.presentation
        return VStack(alignment: .leading, spacing: 14) {
            if result.estimatedDelayMilliseconds == nil {
                Label("No trustworthy delay is available. Review the warnings and repeat the measurement.", systemImage: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                resultMetric("Estimated delay", result.estimatedDelayMilliseconds.map { String(format: "%.3f ms", $0) } ?? "Unavailable")
                resultMetric("Integer delay", result.integerSampleDelay.map { "\($0) samples" } ?? "Unavailable")
                // Parabolic interpolation is an estimate; the UI deliberately
                // avoids implying six-decimal sample accuracy.
                resultMetric("Fractional delay (estimate)", result.fractionalSampleDelay.map { String(format: "%.3f samples", $0) } ?? "Unavailable")
                resultMetric("Sample rate", String(format: "%.0f Hz", result.sampleRateHertz))
                resultMetric("Peak correlation", result.peakCorrelation.map { String(format: "%+.5f", $0) } ?? "Unavailable")
                resultMetric("Polarity", result.polarity)
            }

            warningList(result.warnings)
        }
    }

    private var waveformView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reference and Recording Waveform").font(.headline)
                Spacer()
                Picker("Alignment", selection: alignmentBinding) {
                    Text("Before alignment").tag(WaveformAlignmentMode.unaligned)
                    Text("After alignment").tag(WaveformAlignmentMode.aligned)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .accessibilityLabel("Waveform alignment mode")
            }

            if let data = visualization.waveformData {
                NativeWaveformPlot(
                    data: data,
                    isPreparing: visualization.isPreparingWaveform,
                    zoomAction: visualization.zoomWaveform,
                    panAction: visualization.panWaveform,
                    resetAction: visualization.resetWaveformViewport
                )
                PlotExportButtons(
                    document: PlotExportDocument(
                        title: "AudioLink Lab — Reference and Recording Waveform",
                        content: .waveform(data),
                        appearance: exportAppearance
                    ),
                    suggestedFileName: "audiolink-waveforms.png"
                )
            } else {
                loadingPlaceholder("Preparing waveform envelope…")
            }
        }
    }

    private var correlationView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cross-Correlation Plot").font(.headline)
            if let data = visualization.correlationData {
                NativeCorrelationPlot(
                    data: data,
                    isPreparing: visualization.isPreparingCorrelation,
                    selectedPeakLag: visualization.selectedPeakLag,
                    zoomAction: visualization.zoomCorrelation,
                    panAction: visualization.panCorrelation,
                    resetAction: visualization.resetCorrelationViewport,
                    selectPeakAction: visualization.selectPeak
                )
                PlotExportButtons(
                    document: PlotExportDocument(
                        title: "AudioLink Lab — Cross-Correlation",
                        content: .correlation(data),
                        appearance: exportAppearance
                    ),
                    suggestedFileName: "audiolink-correlation.png"
                )
                candidatePeakList
            } else {
                loadingPlaceholder("Preparing peak-preserving correlation plot…")
            }

            Divider()
            Text("Peak Detail").font(.headline)
            if let detail = visualization.peakDetailData {
                NativePeakDetailPlot(data: detail)
                PlotExportButtons(
                    document: PlotExportDocument(
                        title: "AudioLink Lab — Peak Detail",
                        content: .peakDetail(detail),
                        appearance: exportAppearance
                    ),
                    suggestedFileName: "audiolink-peak-detail.png"
                )
            } else {
                Text("Select a valid correlation peak to inspect its neighborhood.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var candidatePeakList: some View {
        let candidates = analysis.assessment.quality.peakAmbiguity.candidates
        return VStack(alignment: .leading, spacing: 7) {
            Text("Candidate Peaks").font(.subheadline.bold())
            if candidates.isEmpty {
                Text("No peak candidates are available.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(candidates.enumerated()), id: \.offset) { index, peak in
                    candidatePeakRow(index: index, peak: peak)
                }
            }
        }
    }

    private func candidatePeakRow(index: Int, peak: CorrelationPeak) -> some View {
        let lag = peak.fractionalLag ?? Double(peak.lag.rawValue)
        let isSelected: Bool
        if let selected = visualization.selectedPeakLag {
            isSelected = abs(selected - lag) < 0.001
        } else {
            isSelected = false
        }
        let background = isSelected ? accentColor.opacity(0.12) : Color.secondary.opacity(0.06)
        return Button {
            visualization.selectPeak(nearestTo: lag)
        } label: {
            HStack {
                Text(index == 0 ? "Primary" : "Candidate \(index + 1)")
                Spacer()
                Text(String(format: "%+.4f samples", lag)).monospacedDigit()
                Text(String(format: "%+.5f", peak.value)).monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .padding(7)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
        .controlButtonHover(accentColor: accentColor)
        .accessibilityLabel("Select peak at \(lag) samples with correlation \(peak.value)")
    }

    private var diagnosticsView: some View {
        let quality = analysis.assessment.quality
        let presentation = MeasurementQualityFormatter().presentation(for: quality)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(presentation.title, systemImage: qualitySymbol(quality.level))
                    .font(.headline)
                Spacer()
                Text(presentation.scoreText).font(.headline.monospacedDigit())
            }
            Text("The score is accompanied by its measured components; it is not an opaque pass/fail value.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 10)], spacing: 10) {
                ForEach(presentation.keyMetrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.title).font(.subheadline.bold())
                        Text(metric.formattedValue).font(.title3.monospacedDigit())
                        Text(metric.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            warningList(presentation.warnings)
            if !presentation.acousticWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Possible acoustic-path observations").font(.headline)
                    ForEach(presentation.acousticWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "waveform.badge.exclamationmark")
                            .font(.callout)
                    }
                }
            }
            if !presentation.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recommended actions").font(.headline)
                    ForEach(presentation.recommendations, id: \.self) { recommendation in
                        Label(recommendation, systemImage: "arrow.right.circle")
                    }
                }
            }
        }
    }

    private var processingLogView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Processing Log").font(.headline)
            Text("Only explicitly configured transformations are listed. File paths are intentionally omitted.")
                .font(.callout)
                .foregroundStyle(.secondary)
            processingTrack("Reference", file: analysis.preparedReference)
            processingTrack("Recording", file: analysis.preparedRecording)
        }
    }

    private func processingTrack(_ title: String, file: ImportedAudioFile) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                Text("\(file.frameCount) frames · \(file.channelCount) ch · \(file.sampleRate.hertz, specifier: "%.0f") Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if file.preprocessingLog.isEmpty {
                Label("No preprocessing transformations", systemImage: "equal.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(file.preprocessingLog.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(entry.sequence + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.operation.summary)
                            Text("\(entry.inputFrameCount) → \(entry.outputFrameCount) frames")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func warningList(_ warnings: [QualityIssuePresentation]) -> some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Warnings").font(.headline)
                ForEach(warnings) { warning in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: issueSymbol(warning.severity))
                            .foregroundStyle(issueColor(warning.severity))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.title).fontWeight(.semibold)
                            Text(warning.detail).foregroundStyle(.secondary)
                            Text("Recommended: \(warning.recommendation)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func resultMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func loadingPlaceholder(_ title: String) -> some View {
        HStack { ProgressView(); Text(title) }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var alignmentBinding: Binding<WaveformAlignmentMode> {
        Binding(
            get: { visualization.alignmentMode },
            set: { newValue in visualization.setAlignment(newValue) }
        )
    }

    private var exportAppearance: PlotExportAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private func qualityTitle(_ level: MeasurementQualityLevel) -> String {
        switch level {
        case .excellent: "Excellent quality"
        case .good: "Good quality"
        case .questionable: "Questionable quality"
        case .poor: "Poor quality"
        case .invalid: "Invalid measurement"
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

    private func issueSymbol(_ severity: QualityIssueSeverity) -> String {
        switch severity {
        case .information: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        case .fatal: "xmark.octagon.fill"
        }
    }

    private func issueColor(_ severity: QualityIssueSeverity) -> Color {
        switch severity {
        case .information: .blue
        case .warning: .orange
        case .error, .fatal: .red
        }
    }
}
