import AppKit
import AudioLinkCore
import AudioLinkDSP
import AudioLinkStorage
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 13.0, *)
struct NewMeasurementView: View {
    @ObservedObject var viewModel: NewMeasurementViewModel
    let accentColor: Color
    let motionProfile: VersionedMotionProfile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pendingFileRole = NewMeasurementFileRole.reference
    @State private var presentsFileImporter = false
    @State private var advancedSettingsExpanded = false

    private var supportedAudioTypes: [UTType] {
        [UTType(filenameExtension: "wav") ?? .audio]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
                .versionedComponentAppear(profile: motionProfile, pageID: "files-header", direction: .downward)
            workflowProgress
                .versionedComponentAppear(profile: motionProfile, pageID: "files-workflow", direction: .downward)
            fileSelection
                .versionedComponentAppear(profile: motionProfile, pageID: "files-selection", direction: .downward)
            configurationPanel
                .versionedComponentAppear(profile: motionProfile, pageID: "files-configuration", direction: .downward)
            operationControls
                .versionedComponentAppear(profile: motionProfile, pageID: "files-controls", direction: .downward)
            statusContent
                .versionedComponentAppear(profile: motionProfile, pageID: "files-status", direction: .downward)
        }
        .frame(maxWidth: AudioLinkLayoutMetrics.maximumMeasurementContentWidth, alignment: .leading)
        .fileImporter(
            isPresented: $presentsFileImporter,
            allowedContentTypes: supportedAudioTypes,
            allowsMultipleSelection: false
        ) { outcome in
            switch outcome {
            case let .success(urls):
                if let url = urls.first {
                    viewModel.selectFile(url, role: pendingFileRole)
                }
            case let .failure(error):
                let nsError = error as NSError
                if nsError.code != NSUserCancelledError {
                    viewModel.report(error)
                }
            }
        }
        .animation(
            reduceMotion || motionProfile.disablesMotion ? nil : motionProfile.settleAnimation,
            value: viewModel.state
        )
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                headerCopy
                Spacer(minLength: 18)
                openFileButton
            }
            VStack(alignment: .leading, spacing: 12) {
                headerCopy
                openFileButton
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("New Measurement")
                .font(.largeTitle.bold())
            Text("Compare a reference WAV with a recorded WAV to estimate end-to-end audio delay.")
                .foregroundStyle(.secondary)
        }
    }

    private var openFileButton: some View {
        Button {
            openFilePicker(for: viewModel.suggestedOpenRole)
        } label: {
            Label("Open WAV…", systemImage: "folder")
        }
        .keyboardShortcut("o", modifiers: .command)
        .help("Select the next required WAV file (Command-O)")
        .accessibilityLabel("Open WAV file")
        .controlButtonHover(accentColor: accentColor)
    }

    private var workflowProgress: some View {
        HStack(spacing: 0) {
            workflowStep(number: 1, title: "Select Reference", isComplete: viewModel.referenceFile != nil, isCurrent: viewModel.referenceFile == nil)
            workflowConnector(isComplete: viewModel.referenceFile != nil)
            workflowStep(number: 2, title: "Select Recording", isComplete: viewModel.recordingFile != nil, isCurrent: viewModel.referenceFile != nil && viewModel.recordingFile == nil)
            workflowConnector(isComplete: viewModel.filesAreReady)
            workflowStep(number: 3, title: "Configure", isComplete: viewModel.filesAreReady, isCurrent: viewModel.filesAreReady && viewModel.result == nil && viewModel.state != .analyzing)
            workflowConnector(isComplete: viewModel.state == .analyzing || viewModel.state == .completed)
            workflowStep(number: 4, title: "Analyze", isComplete: viewModel.state == .completed, isCurrent: viewModel.state == .analyzing)
            workflowConnector(isComplete: viewModel.state == .completed)
            workflowStep(number: 5, title: "Review Result", isComplete: viewModel.state == .completed, isCurrent: viewModel.state == .completed)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .interactivePanel(cornerRadius: 14, accentColor: accentColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Measurement workflow")
    }

    private func workflowStep(number: Int, title: String, isComplete: Bool, isCurrent: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3)
                .foregroundStyle(isComplete || isCurrent ? accentColor : .secondary)
            Text(title)
                .font(.caption.weight(isCurrent ? .semibold : .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isComplete ? "Complete" : isCurrent ? "Current step" : "Not started")
    }

    private func workflowConnector(isComplete: Bool) -> some View {
        Rectangle()
            .fill(isComplete ? accentColor : Color.secondary.opacity(0.25))
            .frame(width: 20, height: 2)
            .accessibilityHidden(true)
    }

    private var fileSelection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                fileCard(for: .reference)
                    .frame(minWidth: AudioLinkLayoutMetrics.pairedPanelMinimumWidth)
                fileCard(for: .recording)
                    .frame(minWidth: AudioLinkLayoutMetrics.pairedPanelMinimumWidth)
            }
            VStack(alignment: .leading, spacing: 14) {
                fileCard(for: .reference)
                fileCard(for: .recording)
            }
        }
    }

    private func fileCard(for role: NewMeasurementFileRole) -> some View {
        AudioFileSelectionCard(
            role: role,
            file: role == .reference ? viewModel.referenceFile : viewModel.recordingFile,
            preprocessingStatus: viewModel.preprocessingStatus(for: role),
            accentColor: accentColor,
            chooseAction: { openFilePicker(for: role) },
            removeAction: { viewModel.removeFile(role) },
            dropAction: { viewModel.selectFile($0, role: role) }
        )
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Configure", systemImage: "slider.horizontal.3")
                    .font(.title3.bold())
                Spacer()
                Text("Defaults work well for most loopback recordings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    configurationLabel("Reference channel")
                    channelPicker(
                        title: "Reference channel",
                        selection: $viewModel.configuration.referenceChannel,
                        count: viewModel.referenceFile?.channelCount ?? 1
                    )
                    configurationLabel("Recording channel")
                    channelPicker(
                        title: "Recording channel",
                        selection: $viewModel.configuration.recordingChannel,
                        count: viewModel.recordingFile?.channelCount ?? 1
                    )
                }
                GridRow {
                    configurationLabel("Minimum delay")
                    delayField(value: $viewModel.configuration.minimumDelayMilliseconds, label: "Minimum delay in milliseconds")
                    configurationLabel("Maximum delay")
                    delayField(value: $viewModel.configuration.maximumDelayMilliseconds, label: "Maximum delay in milliseconds")
                }
                GridRow {
                    configurationLabel("Polarity")
                    Picker("Polarity handling", selection: $viewModel.configuration.polarityHandling) {
                        ForEach(NewMeasurementPolarityHandling.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    configurationLabel("Normalization")
                    Picker("Normalization", selection: $viewModel.configuration.normalization) {
                        ForEach(NewMeasurementNormalization.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    configurationLabel("Resampling")
                    Picker("Resampling strategy", selection: $viewModel.configuration.resamplingStrategy) {
                        ForEach(NewMeasurementResamplingStrategy.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    configurationLabel("Correlation")
                    Picker("Correlation implementation", selection: $viewModel.configuration.correlationMethod) {
                        Text("Automatic").tag(CorrelationMethod.automatic)
                        Text("Direct").tag(CorrelationMethod.direct)
                        Text("FFT").tag(CorrelationMethod.fft)
                    }
                    .labelsHidden()
                }
            }
            .disabled(viewModel.state.isBusy)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) {
                    preprocessingToggles
                }
                VStack(alignment: .leading, spacing: 8) {
                    preprocessingToggles
                }
            }
            .disabled(viewModel.state.isBusy)

            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        historyPrivacyLabel
                        historyPrivacyPicker
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        historyPrivacyLabel
                        historyPrivacyPicker
                            .frame(maxWidth: .infinity)
                    }
                }
                Text(viewModel.savePolicy.privacyExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced Settings", isExpanded: $advancedSettingsExpanded) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        configurationLabel("High-pass cutoff")
                        HStack {
                            TextField(
                                "High-pass cutoff",
                                value: $viewModel.configuration.highPassCutoffHertz,
                                format: .number.precision(.fractionLength(0...2))
                            )
                            .frame(width: 100)
                            Text("Hz").foregroundStyle(.secondary)
                        }
                        .disabled(!viewModel.configuration.highPassEnabled)
                        configurationLabel("Minimum overlap")
                        HStack {
                            Slider(value: $viewModel.configuration.minimumOverlapRatio, in: 0.1...1, step: 0.05)
                            Text(viewModel.configuration.minimumOverlapRatio, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                    GridRow {
                        configurationLabel("Subsample delay")
                        Toggle("Use parabolic peak interpolation", isOn: $viewModel.configuration.interpolateSubsample)
                        Color.clear
                        Color.clear
                    }
                }
                .padding(.top, 10)
                .disabled(viewModel.state.isBusy)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.18))
        }
        .interactivePanel(cornerRadius: 16, accentColor: accentColor)
    }

    @ViewBuilder
    private var preprocessingToggles: some View {
        Toggle("Mono downmix", isOn: $viewModel.configuration.downmixToMono)
        Toggle("Remove DC offset", isOn: $viewModel.configuration.removeDCOffset)
        Toggle("High-pass filter", isOn: $viewModel.configuration.highPassEnabled)
    }

    private var historyPrivacyLabel: some View {
        Label("History privacy", systemImage: "lock.shield")
            .font(.subheadline.weight(.semibold))
    }

    private var historyPrivacyPicker: some View {
        Picker("History save policy", selection: $viewModel.savePolicy) {
            ForEach(MeasurementSavePolicy.allCases, id: \.self) { policy in
                Text(policy.userTitle).tag(policy)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 340)
    }

    private func configurationLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 126, alignment: .leading)
    }

    private func channelPicker(title: String, selection: Binding<Int>, count: Int) -> some View {
        Picker(title, selection: selection) {
            ForEach(0..<max(1, count), id: \.self) { channel in
                Text("Channel \(channel + 1)").tag(channel)
            }
        }
        .labelsHidden()
        .disabled(viewModel.configuration.downmixToMono)
    }

    private func delayField(value: Binding<Double>, label: String) -> some View {
        HStack {
            TextField(label, value: value, format: .number.precision(.fractionLength(0...3)))
                .frame(minWidth: 90)
                .accessibilityLabel(label)
            Text("ms")
                .foregroundStyle(.secondary)
        }
    }

    private var operationControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                operationControlContent
            }
            VStack(alignment: .leading, spacing: 10) {
                operationControlContent
            }
        }
    }

    @ViewBuilder
    private var operationControlContent: some View {
            Button {
                viewModel.analyze()
            } label: {
                Label("Analyze", systemImage: "waveform.path.ecg.rectangle")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canAnalyze)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Analyze the selected files (Command-Return)")
            .accessibilityLabel("Analyze reference and recording")
            .controlButtonHover(accentColor: accentColor)

            if viewModel.state.isBusy {
                Button(role: .cancel) {
                    viewModel.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .accessibilityLabel("Cancel current import or analysis")
            }

            stateLabel
            historySaveLabel
            Spacer()
    }

    @ViewBuilder
    private var historySaveLabel: some View {
        switch viewModel.historySaveState {
        case .idle:
            EmptyView()
        case .saving:
            ProgressView().controlSize(.small)
            Text("Saving private history…").foregroundStyle(.secondary)
        case .saved:
            Label("Saved to History", systemImage: "externaldrive.badge.checkmark")
                .foregroundStyle(.secondary)
        case .skipped:
            Label("History not saved", systemImage: "eye.slash")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            Button("Retry Save") { viewModel.retryHistorySave() }
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch viewModel.state {
        case .idle:
            Label("Select two WAV files", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case let .importing(role):
            ProgressView().controlSize(.small)
            Text("Importing \(role.displayName.lowercased())…")
        case .ready:
            Label("Ready to analyze", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .analyzing:
            ProgressView().controlSize(.small)
            Text("Analyzing without blocking the interface…")
        case .completed:
            Label("Analysis complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(accentColor)
        case .failed:
            Label("Action required", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .cancelled:
            Label("Cancelled — files and settings are preserved", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if let failure = viewModel.activeFailure {
            failurePanel(failure)
        }
        if let result = viewModel.result, case .completed = viewModel.state {
            resultPanel(result)
        }
    }

    private func failurePanel(_ failure: NewMeasurementFailure) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.title).font(.headline)
                Text(failure.message)
                Text(failure.recoverySuggestion)
                    .foregroundStyle(.secondary)
                Button("Dismiss and Adjust") {
                    viewModel.recover()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.35))
        }
        .interactivePanel(cornerRadius: 14, accentColor: .orange)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Analysis error: \(failure.title)")
    }

    private func resultPanel(_ analysis: NewMeasurementAnalysis) -> some View {
        MeasurementResultReview(
            analysis: analysis,
            accentColor: accentColor,
            motionProfile: motionProfile
        )
            .id(analysis.id)
    }

    private func openFilePicker(for role: NewMeasurementFileRole) {
        pendingFileRole = role
        presentsFileImporter = true
    }
}

@available(macOS 13.0, *)
private struct AudioFileSelectionCard: View {
    let role: NewMeasurementFileRole
    let file: ImportedAudioFile?
    let preprocessingStatus: [String]
    let accentColor: Color
    let chooseAction: () -> Void
    let removeAction: () -> Void
    let dropAction: (URL) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(role == .reference ? "Reference WAV" : "Recording WAV", systemImage: role == .reference ? "waveform" : "mic.fill")
                    .font(.headline)
                Spacer()
                if file != nil {
                    Button(role: .destructive, action: removeAction) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(role.displayName.lowercased()) file")
                    .accessibilityLabel("Remove \(role.displayName.lowercased()) file")
                }
            }

            if let file {
                Text(file.fileName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.fileName)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    fileMetric("Duration", String(format: "%.3f s", file.duration.value))
                    fileMetric("Sample rate", String(format: "%.0f Hz", file.sampleRate.hertz))
                    fileMetric("Channels", "\(file.channelCount)")
                    fileMetric("Format", formatDescription(file))
                    fileMetric("Peak", String(format: "%.5f", file.peakMagnitude))
                    fileMetric("RMS", String(format: "%.5f", file.rootMeanSquare))
                    fileMetric("Clipping", clippingDescription(file))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Preprocessing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(preprocessingStatus, id: \.self) { operation in
                        Label(operation, systemImage: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.largeTitle)
                        .foregroundStyle(isDropTargeted ? accentColor : .secondary)
                    Text("Drop a WAV here")
                        .font(.headline)
                    Text("or choose a file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 178)
            }

            Button(action: chooseAction) {
                Label(file == nil ? "Select \(role.displayName)…" : "Replace \(role.displayName)…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel(file == nil ? "Select \(role.displayName) WAV" : "Replace \(role.displayName) WAV")
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isDropTargeted ? accentColor : Color.secondary.opacity(0.2), lineWidth: isDropTargeted ? 2 : 1)
        }
        .interactivePanel(cornerRadius: 16, accentColor: accentColor)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            dropAction(url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(role.displayName) audio file")
        .accessibilityValue(file?.fileName ?? "Not selected")
    }

    private func fileMetric(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    private func formatDescription(_ file: ImportedAudioFile) -> String {
        let container = file.originalFormat.container.rawValue.uppercased()
        let encoding: String
        switch file.originalFormat.encoding {
        case .signedIntegerPCM: encoding = "PCM"
        case .ieeeFloat: encoding = "Float"
        case .compressed: encoding = "Compressed"
        case .unknown: encoding = "Unknown"
        }
        return "\(container) · \(encoding) \(file.originalFormat.bitDepth)-bit"
    }

    private func clippingDescription(_ file: ImportedAudioFile) -> String {
        let sampleCount = max(1, file.audio.samples.count)
        let ratio = Double(file.clippingSampleCount) / Double(sampleCount)
        return "\(file.clippingSampleCount) (\(ratio.formatted(.percent.precision(.fractionLength(3)))))"
    }
}
