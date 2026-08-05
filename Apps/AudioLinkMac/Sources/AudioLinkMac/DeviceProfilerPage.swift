import AudioLinkRealtime
import SwiftUI

@MainActor
final class DeviceProfilerViewModel: ObservableObject {
    @Published private(set) var snapshots: [AudioDeviceSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    private let profiler = AudioDeviceProfiler()

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do { snapshots = try await profiler.snapshots(); errorMessage = nil }
            catch { errorMessage = "Core Audio capability inspection failed: \(error.localizedDescription)" }
        }
    }

    func summary(for snapshot: AudioDeviceSnapshot) -> String {
        let rate = snapshot.nominalSampleRate.map { String(format: "%.0f Hz", $0.hertz) } ?? "unavailable"
        return "\(snapshot.name) · \(rate) · in \(snapshot.inputChannelCount) / out \(snapshot.outputChannelCount) · transport \(snapshot.transport.rawValue)"
    }

    func copy(_ snapshot: AudioDeviceSnapshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary(for: snapshot), forType: .string)
    }

    func export(_ snapshot: AudioDeviceSnapshot, includeDetailedIdentifiers: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AudioLink-Device-Snapshot.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try snapshot.encodedJSON(includeDetailedIdentifiers: includeDetailedIdentifiers).write(to: url, options: .atomic); errorMessage = nil }
        catch { errorMessage = "Snapshot export failed: \(error.localizedDescription)" }
    }
}

struct DeviceProfilerPage: View {
    private enum DeviceFilter: String, CaseIterable, Identifiable { case all, input, output, aggregate, virtual; var id: String { rawValue }; var title: String { rawValue.capitalized } }
    @StateObject private var viewModel = DeviceProfilerViewModel()
    @State private var selectedID: UUID?
    @State private var includeDetailedIdentifiers = false
    @State private var filter: DeviceFilter = .all

    private var filteredSnapshots: [AudioDeviceSnapshot] {
        viewModel.snapshots.filter { snapshot in
            switch filter {
            case .all: true
            case .input: snapshot.inputChannelCount > 0
            case .output: snapshot.outputChannelCount > 0
            case .aggregate: snapshot.isAggregateDevice
            case .virtual: snapshot.isVirtualDevice
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(filteredSnapshots, selection: $selectedID) { snapshot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.name).font(.headline).lineLimit(1)
                    Text(snapshot.transport.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }.tag(snapshot.id)
            }.frame(minWidth: 230, maxWidth: 280)
            Divider()
            ScrollView {
                if let selectedID, let snapshot = filteredSnapshots.first(where: { $0.id == selectedID }) { detail(snapshot) }
                else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path").font(.title)
                        Text("Select a device").font(.headline)
                        Text("Refresh to inspect Core Audio capabilities.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem { Picker("Device category", selection: $filter) { ForEach(DeviceFilter.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu) }
            ToolbarItem { Toggle("Include detailed identifiers", isOn: $includeDetailedIdentifiers).toggleStyle(.checkbox) }
            ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { viewModel.refresh() }.disabled(viewModel.isRefreshing) }
        }
        .onAppear { viewModel.refresh() }
        .alert("Device Profiler", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) { Button("OK") {} } message: { Text(viewModel.errorMessage ?? "") }
    }

    @ViewBuilder private func detail(_ snapshot: AudioDeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(snapshot.name).font(.title2.weight(.semibold)); Spacer(); Button("Copy Technical Summary") { viewModel.copy(snapshot) }; Button("Export Snapshot") { viewModel.export(snapshot, includeDetailedIdentifiers: includeDetailedIdentifiers) } }
            GroupBox("Overview") { Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow { Text("Manufacturer").foregroundStyle(.secondary); Text(snapshot.manufacturer ?? "Unavailable") }
                GridRow { Text("Device UID").foregroundStyle(.secondary); Text(snapshot.deviceUID ?? "Unavailable") }
                GridRow { Text("Transport").foregroundStyle(.secondary); Text(snapshot.transport.rawValue) }
                GridRow { Text("Alive / running").foregroundStyle(.secondary); Text("\(snapshot.isAlive.map(String.init) ?? "?") / \(snapshot.isRunning.map(String.init) ?? "?")") }
                GridRow { Text("Channels").foregroundStyle(.secondary); Text("input \(snapshot.inputChannelCount), output \(snapshot.outputChannelCount)") }
            }.padding(8) }
            GroupBox("Buffer and Latency") { Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow { Text("Nominal rate").foregroundStyle(.secondary); Text(snapshot.nominalSampleRate.map { String(format: "%.1f Hz", $0.hertz) } ?? "Unavailable").monospacedDigit() }
                GridRow { Text("Buffer").foregroundStyle(.secondary); Text(snapshot.bufferFrameSize.map(String.init) ?? "Unavailable") }
                GridRow { Text("Advertised range").foregroundStyle(.secondary); Text(snapshot.availableBufferFrameSizeRange.map { "\($0.minimum)…\($0.maximum)" } ?? "Unavailable") }
                GridRow { Text("Latency / safety").foregroundStyle(.secondary); Text("\(snapshot.latencyFrames.map(String.init) ?? "?") / \(snapshot.safetyOffsetFrames.map(String.init) ?? "?") frames") }
            }.padding(8) }
            GroupBox("Streams and capabilities") { VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.streams, id: \.objectID) { stream in Text("\(stream.scope.rawValue.capitalized): \(stream.channels.count) channels") }
                ForEach(snapshot.capabilities, id: \.key) { capability in Label("\(capability.key): advertised \(capability.advertised ? "yes" : "no"), verified \(capability.verified.map(String.init) ?? "not tested")", systemImage: capability.verified == true ? "checkmark.circle" : "questionmark.circle") }
            }.padding(8) }
            DisclosureGroup("Raw Diagnostics") {
                let errors = snapshot.propertyErrors.map { $0.localizedDescription }
                Text((snapshot.rawDiagnostics.map { "\($0.key): \($0.value)" } + errors).joined(separator: "\n"))
                    .font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
}
