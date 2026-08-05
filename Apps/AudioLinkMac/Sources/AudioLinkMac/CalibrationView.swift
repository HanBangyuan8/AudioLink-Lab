import AudioLinkCore
import AudioLinkRealtime
import AudioLinkStorage
import SwiftUI

@MainActor
final class CalibrationViewModel: ObservableObject {
    @Published private(set) var profiles: [CalibrationProfile] = []
    @Published private(set) var devices: [AudioDeviceDescription] = []
    @Published var profileName = "Loopback calibration"
    @Published var inputDeviceID = ""
    @Published var outputDeviceID = ""
    @Published var inputChannel = 0
    @Published var outputChannel = 0
    @Published var sampleRateHz = 48_000.0
    @Published var bufferFrameCount = 512
    @Published var knownDelayMilliseconds = 0.0
    @Published var confidence = 0.9
    @Published var method: CalibrationMethod = .manualKnownDelay
    @Published var subtractOffsetByDefault = true
    @Published var notes = ""
    @Published var message: String?
    @Published var isLoading = false

    private let repository: any MeasurementRepository
    private let deviceService: any AudioDeviceService

    init(repository: any MeasurementRepository, deviceService: any AudioDeviceService) {
        self.repository = repository
        self.deviceService = deviceService
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            profiles = try await repository.calibrationProfiles()
            devices = try await deviceService.devices()
            if inputDeviceID.isEmpty { inputDeviceID = devices.first(where: { $0.descriptor.supportsInput })?.descriptor.id ?? "" }
            if outputDeviceID.isEmpty { outputDeviceID = devices.first(where: { $0.descriptor.supportsOutput })?.descriptor.id ?? "" }
        } catch {
            message = "Calibration storage or device discovery is unavailable: \(error.localizedDescription)"
        }
    }

    func saveProfile() async {
        do {
            guard let sampleRate = try? SampleRate(hertz: sampleRateHz), sampleRateHz.isFinite, sampleRateHz > 0 else {
                throw CalibrationMatchFailure.invalidProfile("Sample rate must be a positive finite value.")
            }
            guard let input = devices.first(where: { $0.descriptor.id == inputDeviceID })?.descriptor
                    ?? DeviceDescriptor(id: inputDeviceID, name: inputDeviceID.isEmpty ? "Input" : inputDeviceID, supportsInput: true, supportsOutput: false) as DeviceDescriptor?,
                  let output = devices.first(where: { $0.descriptor.id == outputDeviceID })?.descriptor
                    ?? DeviceDescriptor(id: outputDeviceID, name: outputDeviceID.isEmpty ? "Output" : outputDeviceID, supportsInput: false, supportsOutput: true) as DeviceDescriptor? else {
                throw CalibrationMatchFailure.invalidProfile("Both input and output devices are required.")
            }
            let offsetSamples = Int64((knownDelayMilliseconds / 1_000 * sampleRate.hertz).rounded())
            let profile = CalibrationProfile(
                profileName: profileName,
                inputDevice: input,
                outputDevice: output,
                channelMapping: CalibrationChannelMapping(inputChannel: inputChannel, outputChannel: outputChannel),
                sampleRate: sampleRate,
                bufferFrameCount: bufferFrameCount,
                knownFixedDelay: CalibrationOffset(sampleCount: SampleCount(rawValue: offsetSamples), sampleRate: sampleRate),
                notes: notes,
                confidence: confidence,
                calibrationMethod: method,
                subtractOffsetByDefault: subtractOffsetByDefault
            )
            try await repository.saveCalibrationProfile(profile)
            profiles = try await repository.calibrationProfiles()
            message = "Saved (profile.profileName). Raw delay remains unchanged; calibrated delay is derived when the profile is applied."
        } catch {
            message = error.localizedDescription
        }
    }

    func delete(_ profile: CalibrationProfile) async {
        do {
            try await repository.deleteCalibrationProfile(id: profile.id)
            profiles.removeAll { $0.id == profile.id }
        } catch { message = error.localizedDescription }
    }
}

struct CalibrationView: View {
    @ObservedObject var viewModel: CalibrationViewModel
    let accentColor: Color
    let motionProfile: VersionedMotionProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                profileForm
                profileList
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.bottom, 24)
        }
        .task { await viewModel.load() }
        .tint(accentColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device Calibration").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Create a route-specific offset. Raw measurements are retained; a corrected value is always derived and never overwrites the original.")
                .foregroundStyle(.secondary)
        }
    }

    private var profileForm: some View {
        GroupBox("Calibration profile") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Profile name", text: $viewModel.profileName)
                HStack {
                    Picker("Input", selection: $viewModel.inputDeviceID) {
                        Text("Manual device ID").tag("")
                        ForEach(viewModel.devices.filter { $0.descriptor.supportsInput }, id: \.descriptor.id) { device in Text(device.name).tag(device.descriptor.id) }
                    }
                    Picker("Output", selection: $viewModel.outputDeviceID) {
                        Text("Manual device ID").tag("")
                        ForEach(viewModel.devices.filter { $0.descriptor.supportsOutput }, id: \.descriptor.id) { device in Text(device.name).tag(device.descriptor.id) }
                    }
                }
                HStack {
                    TextField("Input channel", value: $viewModel.inputChannel, format: .number)
                    TextField("Output channel", value: $viewModel.outputChannel, format: .number)
                    TextField("Sample rate", value: $viewModel.sampleRateHz, format: .number)
                    TextField("Buffer frames", value: $viewModel.bufferFrameCount, format: .number)
                }
                HStack {
                    TextField("Known fixed delay (ms)", value: $viewModel.knownDelayMilliseconds, format: .number.precision(.fractionLength(3)))
                    TextField("Confidence 0…1", value: $viewModel.confidence, format: .number.precision(.fractionLength(2)))
                }
                Picker("Method", selection: $viewModel.method) {
                    Text("Manual known delay").tag(CalibrationMethod.manualKnownDelay)
                    Text("Physical loopback").tag(CalibrationMethod.physicalLoopback)
                }
                Toggle("Subtract offset by default", isOn: $viewModel.subtractOffsetByDefault)
                TextField("Notes", text: $viewModel.notes)
                HStack {
                    Button("Save Calibration Profile") { Task { await viewModel.saveProfile() } }
                        .buttonStyle(.borderedProminent)
                    Button("Refresh Devices") { Task { await viewModel.load() } }
                }
                if let message = viewModel.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(4)
        }
    }

    private var profileList: some View {
        GroupBox("Saved profiles") {
            if viewModel.profiles.isEmpty {
                Text("No calibration profiles yet.").foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.profileName).font(.headline)
                            Text("\(profile.inputDevice.name) → \(profile.outputDevice.name) · \(profile.sampleRate.hertz.formatted()) Hz · offset \(profile.knownFixedDelay.milliseconds.formatted(.number.precision(.fractionLength(3)))) ms")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text(profile.calibrationMethod == .physicalLoopback ? "Physical loopback · heuristic confidence (profile.confidence.formatted(.percent.precision(.fractionLength(0))))" : "Manual delay · confidence (profile.confidence.formatted(.percent.precision(.fractionLength(0))))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { Task { await viewModel.delete(profile) } }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
