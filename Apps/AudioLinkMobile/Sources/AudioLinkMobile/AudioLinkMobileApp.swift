import AudioLinkNetworking
import SwiftUI

@main
struct AudioLinkMobileApp: App {
    @StateObject private var model: MobileSessionController

    init() {
        _model = StateObject(wrappedValue: MobileSessionController())
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
                .tint(.accentColor)
        }
    }
}

struct MobileRootView: View {
    @ObservedObject var model: MobileSessionController

    var body: some View {
        TabView {
            NearbyDevicesView(model: model)
                .tabItem { Label("Nearby Devices", systemImage: "dot.radiowaves.left.and.right") }
            MeasurementProgressView(model: model)
                .tabItem { Label("Measurement", systemImage: "waveform.path.ecg") }
            DiagnosticsView(model: model)
                .tabItem { Label("Diagnostics", systemImage: "waveform.and.magnifyingglass") }
            MobileSettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { model.startDiscovery() }
    }
}

struct NearbyDevicesView: View {
    @ObservedObject var model: MobileSessionController

    var body: some View {
        NavigationStack {
            List {
                Section("Device Role") {
                    Picker("This iPhone", selection: $model.localRole) {
                        Text("Recorder").tag(PeerRole.recorder)
                        Text("Player").tag(PeerRole.player)
                    }
                    .accessibilityLabel("This iPhone role")
                    Picker("Remote device", selection: $model.remoteRole) {
                        Text("Recorder").tag(PeerRole.recorder)
                        Text("Player").tag(PeerRole.player)
                    }
                    .accessibilityLabel("Remote device role")
                }

                Section("Nearby Devices") {
                    if model.discoveredPeers.isEmpty {
                        Label("No AudioLink devices found yet.", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.discoveredPeers) { peer in
                        Button {
                            Task { await model.connect(to: peer) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(peer.identity.displayName)
                                        .font(.headline)
                                    Text(peer.endpointDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("Connect to \(peer.identity.displayName)")
                    }
                }

                if case .pairing = model.state {
                    PairingCard(model: model)
                }

                Section {
                    Text(model.statusText)
                        .font(.headline)
                        .accessibilityValue(model.statusText)
                    if let error = model.lastError {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("AudioLink Mobile")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        model.startDiscovery()
                    } label: {
                        Label("Refresh devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }
}

struct PairingCard: View {
    @ObservedObject var model: MobileSessionController

    var body: some View {
        Section("Pairing") {
            Text("Compare the six-digit code on both devices before accepting.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Six-digit code", text: $model.pairingCodeText)
#if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
#endif
                .accessibilityLabel("Six-digit pairing code")
            HStack {
                Button("Confirm pairing") {
                    Task { await model.confirmPairing() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.pairingCodeText.count != 6)
                .accessibilityHint("Only accept after comparing the code with the Mac")
                Button("Request pairing") {
                    Task { await model.requestPairing() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct MeasurementProgressView: View {
    @ObservedObject var model: MobileSessionController

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: model.state.isActive ? "waveform.path.ecg" : "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(model.state.isActive ? .blue : .secondary)
                    .accessibilityHidden(true)
                Text(model.statusText)
                    .font(.title2.weight(.semibold))
                ProgressView(value: model.progress)
                    .padding(.horizontal)
                if let peer = model.selectedPeer {
                    Text("Connected to \(peer.identity.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if case .paired = model.state {
                    Button("Start Measurement") {
                        Task { await model.beginMeasurement() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Start measurement")
                }
                if model.isBusy {
                    Button("Stop") {
                        Task { await model.cancelMeasurement() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Stop measurement")
                }
                if case let .completed(summary) = model.state {
                    ResultSummaryCard(summary: summary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Ready Screen")
        }
    }
}

struct ResultSummaryCard: View {
    let summary: MobileMeasurementSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measurement complete")
                .font(.headline)
            LabeledContent("Role", value: summary.role.rawValue)
            LabeledContent("Sample rate", value: String(format: "%.0f Hz", summary.sampleRateHertz))
            LabeledContent("Result", value: summary.rawDelayMilliseconds.map { String(format: "%.3f ms", $0) } ?? "Final analysis on Mac")
            if let file = summary.recordingFileName {
                LabeledContent("Recording", value: file)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: MobileSessionController

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("State", value: model.statusText)
                    LabeledContent("Network", value: model.networkQualityText)
                    LabeledContent("Messages received", value: "\(model.networkDiagnostics.messagesReceived)")
                    LabeledContent("Messages sent", value: "\(model.networkDiagnostics.messagesSent)")
                }
                Section("iOS Audio Route") {
                    LabeledContent("Microphone permission", value: model.microphonePermission.label)
                    if let route = model.routeSnapshot {
                        LabeledContent("Input", value: route.inputName ?? "None")
                        LabeledContent("Output", value: route.outputName ?? "None")
                        LabeledContent("Sample rate", value: String(format: "%.0f Hz", route.sampleRateHertz))
                        LabeledContent("Input channels", value: "\(route.inputChannelCount)")
                        LabeledContent("Output channels", value: "\(route.outputChannelCount)")
                        LabeledContent("I/O buffer", value: String(format: "%.1f ms", route.ioBufferDurationSeconds * 1_000))
                        LabeledContent("Bluetooth", value: route.supportsBluetooth ? "Connected / route-dependent" : "Not active")
                    } else {
                        Text("Route is read when a role is prepared.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Timing") {
                    Text("Host/sample timestamps arrange the capture window only. Final acoustic latency must come from correlation of the recording.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Local Diagnostics")
            .toolbar {
                Button("Refresh route") { model.refreshRoute() }
                    .accessibilityLabel("Refresh audio route diagnostics")
            }
        }
    }
}

struct MobileSettingsView: View {
    @ObservedObject var model: MobileSessionController

    var body: some View {
        NavigationStack {
            Form {
                Section("Recording privacy") {
                    Toggle("Keep recording on this iPhone", isOn: $model.retainRecording)
                    Text("When disabled, a temporary WAV is removed after a successful transfer. The app does not request background audio and should remain in the foreground during measurement.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Permissions") {
                    Text("Microphone and Local Network permissions are requested only when needed. Bluetooth and speaker routing remain subject to iOS policy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Stop and close session") {
                        Task { await model.shutdown() }
                    }
                    .foregroundStyle(.red)
                    .accessibilityLabel("Stop and close session")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
