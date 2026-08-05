import AudioLinkRealtime
import SwiftUI

@available(macOS 12.0, *)
struct RealtimeMeasurementView: View {
    @ObservedObject var viewModel: RealtimeMeasurementViewModel
    let accentColor: Color
    let motionProfile: VersionedMotionProfile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdvanced = false
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
                .versionedComponentAppear(profile: motionProfile, pageID: "realtime-header", direction: .downward)
            safetyNotice
                .interactivePanel(cornerRadius: 12, accentColor: accentColor)
                .versionedComponentAppear(profile: motionProfile, pageID: "realtime-safety", direction: .downward)
            routeSection
                .interactivePanel(cornerRadius: 12, accentColor: accentColor)
                .versionedComponentAppear(profile: motionProfile, pageID: "realtime-route", direction: .downward)
            settingsSection
                .interactivePanel(cornerRadius: 12, accentColor: accentColor)
                .versionedComponentAppear(profile: motionProfile, pageID: "realtime-settings", direction: .downward)
            controls
                .versionedComponentAppear(profile: motionProfile, pageID: "realtime-controls", direction: .downward)
            if let failure = viewModel.failure {
                failureCard(failure)
                    .interactivePanel(cornerRadius: 12, accentColor: .red)
                    .versionedComponentAppear(profile: motionProfile, pageID: "realtime-failure", direction: .downward)
            }
            if let result = viewModel.result {
                resultCard(result)
                    .interactivePanel(cornerRadius: 12, accentColor: accentColor)
                    .versionedComponentAppear(profile: motionProfile, pageID: "realtime-result", direction: .downward)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Real-time Loopback Measurement")
                .font(.title2.weight(.semibold))
            Text("Play a conservative test sweep, capture the selected input, then estimate end-to-end delay from the recording.")
                .foregroundStyle(.secondary)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refreshDevices() }
        } label: {
            Label(viewModel.isRefreshingDevices ? "Refreshing…" : "Refresh Devices", systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isRefreshingDevices || viewModel.state.isBusy)
        .accessibilityLabel("Refresh Core Audio devices")
        .controlButtonHover(accentColor: accentColor)
    }

    private var safetyNotice: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Lower your output volume before measuring. The default sweep is −15 dBFS, but downstream gain may still be loud.", systemImage: "speaker.wave.2.trianglebadge.exclamationmark")
                    .foregroundStyle(.primary)
                Toggle("I checked the playback volume and connected equipment.", isOn: $viewModel.acknowledgedVolumeWarning)
                Toggle("I understand that open speaker-to-microphone paths can feed back. AudioLink will not monitor the input through the output.", isOn: $viewModel.acknowledgedFeedbackWarning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Safety", systemImage: "exclamationmark.shield")
        }
    }

    private var routeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                devicePicker(
                    title: "Output device",
                    selection: $viewModel.selectedOutputID,
                    devices: viewModel.outputDevices,
                    systemImage: "speaker.wave.2"
                )
                devicePicker(
                    title: "Input device",
                    selection: $viewModel.selectedInputID,
                    devices: viewModel.inputDevices,
                    systemImage: "mic"
                )
                if !viewModel.routeRatesMatch,
                   let input = viewModel.selectedInput,
                   let output = viewModel.selectedOutput {
                    Label(
                        "Incompatible sample rates: input \(Int(input.nominalSampleRate.hertz)) Hz, output \(Int(output.nominalSampleRate.hertz)) Hz. Set both to the same nominal rate in Audio MIDI Setup.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
                if let event = viewModel.latestRouteEvent {
                    Text(event)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Audio Route", systemImage: "arrow.triangle.branch")
        }
    }

    private func devicePicker(
        title: String,
        selection: Binding<String?>,
        devices: [AudioDeviceDescription],
        systemImage: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .frame(width: 138, alignment: .leading)
                deviceSelectionPicker(title: title, selection: selection, devices: devices)
                    .frame(minWidth: 300, maxWidth: 520)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                deviceSelectionPicker(title: title, selection: selection, devices: devices)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func deviceSelectionPicker(
        title: String,
        selection: Binding<String?>,
        devices: [AudioDeviceDescription]
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Choose a device").tag(String?.none)
            ForEach(devices) { device in
                Text(deviceTitle(device)).tag(Optional(device.id))
                }
        }
        .labelsHidden()
    }

    private func deviceTitle(_ device: AudioDeviceDescription) -> String {
        let defaultLabel = device.isDefaultInput || device.isDefaultOutput ? " · System Default" : ""
        let channels = max(device.inputChannelCount, device.outputChannelCount)
        return "\(device.name) · \(Int(device.nominalSampleRate.hertz)) Hz · \(channels) ch\(defaultLabel)"
    }

    private var settingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        channelPickers
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        channelPickers
                    }
                }
                HStack(spacing: 12) {
                    Text("Test level")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $viewModel.amplitude, in: 0.05...0.35, step: 0.01)
                        .frame(maxWidth: 300)
                    Text(String(format: "%.0f%%", viewModel.amplitude * 100))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        calibrationControls
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        calibrationControls
                    }
                }
                DisclosureGroup("Advanced settings", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        numericField("Sweep duration", value: $viewModel.signalDurationSeconds, suffix: "s")
                        numericField("Pre-roll", value: $viewModel.preRollSeconds, suffix: "s")
                        numericField("Post-roll", value: $viewModel.postRollSeconds, suffix: "s")
                        numericField("Maximum delay", value: $viewModel.maximumDelayMilliseconds, suffix: "ms")
                        Picker("Buffer size", selection: $viewModel.bufferFrameCount) {
                            ForEach([128, 256, 512, 1024, 2048], id: \.self) { frames in
                                Text("\(frames) frames").tag(frames)
                            }
                        }
                        .frame(maxWidth: 320)
                        Toggle("Remove DC offset before analysis", isOn: $viewModel.removeDCOffset)
                        Toggle("Apply 20 Hz high-pass before analysis", isOn: $viewModel.highPassEnabled)
                    }
                    .padding(.top, 8)
                }
            }
        } label: {
            Label("Measurement Configuration", systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder
    private var calibrationControls: some View {
        Picker("Calibration profile", selection: $viewModel.selectedCalibrationProfileID) {
            Text("No calibration").tag(UUID?.none)
            ForEach(viewModel.calibrationProfiles) { profile in
                Text(profile.profileName).tag(Optional(profile.id))
            }
        }
        .frame(maxWidth: 300)
        Toggle("Apply calibration offset", isOn: $viewModel.applyCalibrationOffset)
            .disabled(viewModel.selectedCalibrationProfileID == nil)
    }

    @ViewBuilder
    private var channelPickers: some View {
        channelPicker(
            title: "Output channel",
            selection: $viewModel.outputChannel,
            count: viewModel.selectedOutput?.outputChannelCount ?? 0
        )
        channelPicker(
            title: "Input channel",
            selection: $viewModel.inputChannel,
            count: viewModel.selectedInput?.inputChannelCount ?? 0
        )
    }

    private func channelPicker(title: String, selection: Binding<Int>, count: Int) -> some View {
        Picker(title, selection: selection) {
            ForEach(0..<max(1, count), id: \.self) { channel in
                Text("Channel \(channel + 1)").tag(channel)
            }
        }
        .frame(maxWidth: 260)
        .disabled(count == 0 || viewModel.state.isBusy)
    }

    private func numericField(
        _ title: String,
        value: Binding<Double>,
        suffix: String
    ) -> some View {
        HStack {
            Text(title).frame(width: 140, alignment: .leading)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                controlContent
            }
            VStack(alignment: .leading, spacing: 10) {
                controlContent
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var controlContent: some View {
            if viewModel.state.isBusy {
                Button(role: .destructive) {
                    viewModel.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button {
                    viewModel.startMeasurement()
                } label: {
                    Label("Start Real-time Measurement", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(!viewModel.canStart)
                .keyboardShortcut(.return, modifiers: [.command])
                .controlButtonHover(accentColor: accentColor)
            }
            Button {
                viewModel.previewSignal()
            } label: {
                Label("Preview Sweep", systemImage: "play.fill")
            }
            .disabled(!viewModel.canPreview)
            .controlButtonHover(accentColor: accentColor)

            if viewModel.state.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(stateTitle(viewModel.state))
                    .foregroundStyle(.secondary)
            } else if case .cancelled = viewModel.state {
                Label("Cancelled", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
    }

    private func failureCard(_ failure: RealtimeMeasurementFailure) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(failure.userMessage, systemImage: "exclamationmark.octagon")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(failure.recoverySuggestion)
                if failure.code == .permissionDenied {
                    Button("Open Microphone Privacy Settings") {
                        viewModel.openMicrophoneSettings()
                    }
                }
                HStack {
                    Button("Dismiss") { viewModel.recover() }
                    if let technical = failure.technicalContext {
                        Text(technical)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultCard(_ result: RealtimeMeasurementResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        resultHeadline(result)
                        Spacer()
                        qualityBadge(result.assessment.quality.level.rawValue.capitalized)
                        Button("Copy Result") { viewModel.copyResult() }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        resultHeadline(result)
                        HStack {
                            qualityBadge(result.assessment.quality.level.rawValue.capitalized)
                            Button("Copy Result") { viewModel.copyResult() }
                        }
                    }
                }
                Divider()
                metricRow("Integer delay", value: result.assessment.delay.map { "\($0.sampleOffset.rawValue) samples" } ?? "Unavailable")
                metricRow("Fractional delay (estimate)", value: result.assessment.delay?.fractionalSampleOffset.map { String(format: "%.3f samples", $0) } ?? "Unavailable")
                if let calibration = result.assessment.calibration {
                    metricRow("Raw delay", value: String(format: "%.3f ms", calibration.rawDelay.fractionalMilliseconds))
                    metricRow("Calibrated delay", value: calibration.calibratedDelay.map { String(format: "%.3f ms", $0.fractionalMilliseconds) } ?? "Offset not applied")
                    metricRow("Calibration offset", value: String(format: "%.3f ms", calibration.offset.milliseconds))
                }
                metricRow("Peak correlation", value: result.assessment.correlation.map { String(format: "%.4f", $0.normalizedPeak) } ?? "Unavailable")
                metricRow("Confidence", value: String(format: "%.1f%%", result.assessment.quality.confidence.value * 100))
                metricRow("Polarity", value: result.assessment.quality.signal.isPolarityInverted == true ? "Inverted" : "Normal")
                Text(result.assessment.quality.summary)
                    .font(.callout)
                ForEach(result.assessment.quality.issues, id: \.code) { issue in
                    Label(issue.userDescription, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
                if let acoustic = result.assessment.quality.acousticDiagnostics, !acoustic.issues.isEmpty {
                    DisclosureGroup("Possible acoustic-path observations") {
                        ForEach(acoustic.issues) { issue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(issue.statement)
                                Text(issue.evidence).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                DisclosureGroup("Engine diagnostics", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 6) {
                        metricRow("Recording started first", value: result.diagnostics.recordingBeganBeforePlayback ? "Yes" : "No")
                        metricRow("Buffers captured", value: "\(result.diagnostics.recordedBufferCount)")
                        metricRow("Dropped buffers", value: "\(result.diagnostics.droppedBufferCount)")
                        metricRow("Underflow / overflow", value: "\(result.diagnostics.underflowCount) / \(result.diagnostics.overflowCount)")
                        metricRow("Nominal sample rate", value: "\(Int(result.diagnostics.nominalSampleRate.hertz)) Hz")
                        metricRow("History", value: result.savedHistorySessionID == nil ? "Not saved" : "Saved locally (results only)")
                        Text("Software scheduling timestamps are diagnostic only; the displayed delay is derived from recorded audio correlation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
        } label: {
            Label("Measurement Result", systemImage: "checkmark.seal")
        }
    }

    private func resultHeadline(_ result: RealtimeMeasurementResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(delayTitle(result))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("End-to-end delay from recorded-signal correlation")
                .foregroundStyle(.secondary)
        }
    }

    private func delayTitle(_ result: RealtimeMeasurementResult) -> String {
        guard let delay = result.assessment.delay else { return "No reliable delay" }
        return String(format: "%.3f ms", delay.fractionalMilliseconds)
    }

    private func qualityBadge(_ title: String) -> some View {
        Label(title, systemImage: "gauge.with.dots.needle.67percent")
            .font(.headline)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(accentColor.opacity(0.14), in: Capsule())
            .accessibilityLabel("Measurement quality: \(title)")
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func stateTitle(_ state: RealtimeMeasurementState) -> String {
        switch state {
        case .idle: "Ready"
        case .validatingDevices: "Validating devices…"
        case .requestingPermission: "Checking microphone access…"
        case .preparingSignal: "Preparing test signal…"
        case .startingRecording: "Starting recording…"
        case .preRoll: "Stabilizing input…"
        case .playing: "Playing and recording…"
        case .postRoll: "Capturing post-roll…"
        case .preprocessing: "Preprocessing recording…"
        case .analyzing: "Correlating signals…"
        case .saving: "Saving result…"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
