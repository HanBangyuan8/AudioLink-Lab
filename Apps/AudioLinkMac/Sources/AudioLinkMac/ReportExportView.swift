import AppKit
import AudioLinkReporting
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 13.0, *)
struct ReportExportSheet: View {
    let title: String
    let exportAction: (ReportExportFormat, ReportPrivacyOptions, ReportChapterSelection, URL) async throws -> [URL]
    let onDismiss: () -> Void

    @State private var format: ReportExportFormat = .pdf
    @State private var includeIdentifiers = false
    @State private var includeCharts = true
    @State private var includeSetup = true
    @State private var includeDiagnostics = true
    @State private var includeReproducibility = true
    @State private var isExporting = false
    @State private var status: String?
    @State private var exportedURLs: [URL] = []
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Picker("Format", selection: $format) {
                ForEach(ReportExportFormat.allCases) { item in
                    Text(item.rawValue.uppercased()).tag(item)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Include charts", isOn: $includeCharts)
            DisclosureGroup("Report sections") {
                Toggle("Setup, devices and audio format", isOn: $includeSetup)
                Toggle("Quality, warnings, calibration, drift and processing log", isOn: $includeDiagnostics)
                Toggle("Versions and reproducibility", isOn: $includeReproducibility)
            }
            Toggle("Include detailed diagnostic identifiers", isOn: $includeIdentifiers)
                .help("Off by default; source paths, usernames and security bookmarks are never exported.")
            Text("Reports omit absolute paths, home-directory information and security-scoped bookmarks. Device identifiers are included only when explicitly enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isExporting {
                ProgressView("Preparing report…")
                Button("Cancel Export", role: .cancel) {
                    exportTask?.cancel()
                }
            }
            if let status {
                Label(status, systemImage: exportedURLs.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(exportedURLs.isEmpty ? .orange : .green)
            }
            HStack {
                Spacer()
                Button("Close") { onDismiss() }
                Button("Export…") { chooseDestinationAndExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting)
            }
        }
        .padding(22)
        .frame(minWidth: 490)
        .onDisappear { exportTask?.cancel() }
    }

    private func chooseDestinationAndExport() {
        let destination: URL?
        if format == .csv {
            let panel = NSOpenPanel()
            panel.title = "Choose Report Folder"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            destination = panel.runModal() == .OK ? panel.url : nil
        } else {
            let panel = NSSavePanel()
            panel.title = "Save AudioLink Report"
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "audiolink-report.\(format.fileExtension)"
            panel.allowedContentTypes = contentTypes(for: format)
            destination = panel.runModal() == .OK ? panel.url : nil
        }
        guard let destination else { return }
        status = nil
        exportedURLs = []
        isExporting = true
        exportTask = Task {
            do {
                let chapters = ReportChapterSelection(includeAll: true)
                var selectedChapters = chapters
                selectedChapters.charts = includeCharts
                selectedChapters.measurementSetup = includeSetup
                selectedChapters.deviceInformation = includeSetup
                selectedChapters.signalConfiguration = includeSetup
                selectedChapters.audioFormat = includeSetup
                selectedChapters.qualityAndConfidence = includeDiagnostics
                selectedChapters.warnings = includeDiagnostics
                selectedChapters.calibration = includeDiagnostics
                selectedChapters.drift = includeDiagnostics
                selectedChapters.processingLog = includeDiagnostics
                selectedChapters.versions = includeReproducibility
                selectedChapters.reproducibility = includeReproducibility
                let urls = try await exportAction(format, ReportPrivacyOptions(includeDetailedDiagnosticIdentifiers: includeIdentifiers), selectedChapters, destination)
                guard !Task.isCancelled else {
                    await MainActor.run { isExporting = false; status = "Export cancelled." }
                    return
                }
                await MainActor.run {
                    exportedURLs = urls
                    isExporting = false
                    status = "Exported \(urls.count) file(s)."
                }
                if let first = urls.first {
                    NSWorkspace.shared.activateFileViewerSelecting([first])
                }
            } catch is CancellationError {
                await MainActor.run { isExporting = false; status = "Export cancelled." }
            } catch {
                await MainActor.run { isExporting = false; status = error.localizedDescription }
            }
        }
    }

    private func contentTypes(for format: ReportExportFormat) -> [UTType] {
        switch format {
        case .json: [.json]
        case .csv: [.commaSeparatedText]
        case .html: [.html]
        case .pdf: [.pdf]
        case .png: [.png]
        }
    }
}
