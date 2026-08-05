import AppKit
import AudioLinkCore
import AudioLinkDSP
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 13.0, *)
struct NativeWaveformPlot: View {
    let data: WaveformRenderData
    let isPreparing: Bool
    let zoomAction: (Double, Double) -> Void
    let panAction: (Double) -> Void
    let resetAction: () -> Void

    @State private var cursorNormalized: Double?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("Reference", systemImage: "waveform").foregroundStyle(.blue)
                Label("Recording", systemImage: "waveform").foregroundStyle(.orange)
                Spacer()
                plotNavigationButtons(
                    zoomIn: { zoomAction(1.8, 0.5) },
                    zoomOut: { zoomAction(1 / 1.8, 0.5) },
                    reset: resetAction
                )
            }

            GeometryReader { geometry in
                let layout = PlotCanvasLayout(size: geometry.size)
                ZStack(alignment: .topTrailing) {
                    Canvas { context, size in
                        let metrics = PlotCanvasLayout(size: size)
                        drawScaffold(context: &context, layout: metrics)
                        drawWaveformTrack(
                            data.reference,
                            viewport: data.viewport,
                            trackRect: metrics.topTrackRect,
                            color: .blue,
                            context: &context
                        )
                        drawWaveformTrack(
                            data.recording,
                            viewport: data.viewport,
                            trackRect: metrics.bottomTrackRect,
                            color: .orange,
                            context: &context
                        )
                        drawWaveformMarkers(data.markers, viewport: data.viewport, layout: metrics, context: &context)
                        drawSampleTimeAxis(
                            viewport: data.viewport,
                            sampleRate: data.reference.sampleRate.hertz,
                            layout: metrics,
                            context: &context
                        )
                        drawTrackLabel("Reference", rect: metrics.topTrackRect, color: .blue, context: &context)
                        drawTrackLabel("Recording", rect: metrics.bottomTrackRect, color: .orange, context: &context)
                        if let cursorNormalized {
                            drawCursor(normalized: cursorNormalized, layout: metrics, context: &context)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            cursorNormalized = layout.normalizedX(for: location.x)
                        case .ended:
                            cursorNormalized = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onEnded { value in
                                let fraction = Double(value.translation.width / max(1, layout.plotRect.width))
                                panAction(-fraction * data.viewport.visibleSpan)
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onEnded { factor in
                                zoomAction(Double(factor), cursorNormalized ?? 0.5)
                            }
                    )

                    if let cursorNormalized {
                        let sample = data.samplePosition(atNormalizedPosition: cursorNormalized)
                        let seconds = data.timeSeconds(atSamplePosition: sample)
                        PlotCursorReadout(
                            lines: [
                                String(format: "time %.6f s", seconds),
                                String(format: "sample %.2f", sample)
                            ]
                        )
                        .padding(8)
                    }

                    if isPreparing {
                        ProgressView("Preparing display envelope…")
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(8)
                    }
                }
            }
            .frame(height: 320)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.2)) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Reference and recording waveform plot")

            Text("Horizontal axis: seconds and sample position · Vertical axis: normalized amplitude · Drag to pan, pinch or use buttons to zoom")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@available(macOS 13.0, *)
struct NativeCorrelationPlot: View {
    let data: CorrelationRenderData
    let isPreparing: Bool
    let selectedPeakLag: Double?
    let zoomAction: (Double, Double) -> Void
    let panAction: (Double) -> Void
    let resetAction: () -> Void
    let selectPeakAction: (Double) -> Void

    @State private var cursorNormalized: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Positive correlation", systemImage: "plus.circle").foregroundStyle(.purple)
                Label("Negative correlation", systemImage: "minus.circle").foregroundStyle(.indigo)
                Spacer()
                plotNavigationButtons(
                    zoomIn: { zoomAction(1.8, 0.5) },
                    zoomOut: { zoomAction(1 / 1.8, 0.5) },
                    reset: resetAction
                )
            }

            if data.peakAtSearchBoundary {
                Label("Primary peak is at the search boundary; the true delay may be outside the configured range.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            GeometryReader { geometry in
                let layout = PlotCanvasLayout(size: geometry.size)
                ZStack(alignment: .topTrailing) {
                    Canvas { context, size in
                        let metrics = PlotCanvasLayout(size: size)
                        drawScaffold(context: &context, layout: metrics)
                        drawCorrelationEnvelope(data, layout: metrics, context: &context)
                        drawCorrelationThresholds(data, layout: metrics, context: &context)
                        drawCorrelationMarkers(
                            data.markers,
                            viewport: data.viewport,
                            selectedPeakLag: selectedPeakLag,
                            layout: metrics,
                            context: &context
                        )
                        drawCorrelationAxis(data: data, layout: metrics, context: &context)
                        if let cursorNormalized {
                            drawCursor(normalized: cursorNormalized, layout: metrics, context: &context)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            cursorNormalized = layout.normalizedX(for: location.x)
                        case .ended:
                            cursorNormalized = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onEnded { value in
                                let fraction = Double(value.translation.width / max(1, layout.plotRect.width))
                                panAction(-fraction * data.viewport.visibleSpan)
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onEnded { factor in
                                zoomAction(Double(factor), cursorNormalized ?? 0.5)
                            }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { event in
                                selectPeakAction(data.lag(atNormalizedPosition: layout.normalizedX(for: event.location.x)))
                            }
                    )

                    if let cursorNormalized {
                        correlationCursorReadout(data: data, normalized: cursorNormalized)
                            .padding(8)
                    }

                    if isPreparing {
                        ProgressView("Preparing peak-preserving plot…")
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(8)
                    }
                }
            }
            .frame(height: 330)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.2)) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Cross-correlation plot with peak candidates")

            Text("Horizontal axis: lag samples and milliseconds · Vertical axis: normalized signed correlation · Click near a peak for details")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func correlationCursorReadout(
        data: CorrelationRenderData,
        normalized: Double
    ) -> some View {
        let lag = data.lag(atNormalizedPosition: normalized)
        let nearest = data.bins.min { abs(Double($0.strongestLag) - lag) < abs(Double($1.strongestLag) - lag) }
        return PlotCursorReadout(
            lines: [
                String(format: "lag %.2f samples", lag),
                String(format: "%.4f ms", data.milliseconds(forLag: lag)),
                nearest.map { String(format: "r %+.5f", $0.strongestValue) } ?? "r unavailable"
            ]
        )
    }
}

@available(macOS 13.0, *)
struct NativePeakDetailPlot: View {
    let data: PeakDetailRenderData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label("Sampled correlation", systemImage: "point.3.connected.trianglepath.dotted").foregroundStyle(.purple)
                Label("Parabolic interpolation", systemImage: "function").foregroundStyle(.mint)
                Spacer()
                Text(String(format: "noise floor %.5f RMS", data.localNoiseFloor))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Canvas { context, size in
                let layout = PlotCanvasLayout(size: size)
                drawScaffold(context: &context, layout: layout)
                drawPeakDetail(data, layout: layout, context: &context)
                drawCorrelationAxis(
                    data: CorrelationRenderData(
                        sampleRate: data.sampleRate,
                        viewport: data.viewport,
                        bins: [],
                        markers: [],
                        searchRange: SampleLagRange(
                            minimum: Int64(floor(data.viewport.domainLowerBound)),
                            maximum: Int64(ceil(data.viewport.domainUpperBound))
                        ),
                        confidenceThresholdMagnitude: 0,
                        peakAtSearchBoundary: false
                    ),
                    layout: layout,
                    context: &context
                )
            }
            .frame(height: 280)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.2)) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Peak detail plot showing integer and fractional peak positions")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(data.confidenceMetrics) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.title).font(.caption).foregroundStyle(.secondary)
                        Text(peakMetricText(metric))
                            .font(.callout.weight(.semibold).monospacedDigit())
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func peakMetricText(_ metric: PeakDetailMetric) -> String {
        switch metric.unit {
        case "fraction": String(format: "%.1f%%", metric.value * 100)
        case "samples": String(format: "%.3f samples", metric.value)
        case "dB": String(format: "%.2f dB", metric.value)
        default: String(format: "%+.5f %@", metric.value, metric.unit)
        }
    }
}

@available(macOS 13.0, *)
struct PlotExportButtons: View {
    let document: PlotExportDocument
    let suggestedFileName: String
    var width = 1_600
    var height = 900

    @State private var statusText: String?
    @State private var isWorking = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                copyPNG()
            } label: {
                Label("Copy Chart", systemImage: "photo.on.rectangle")
            }
            .disabled(isWorking)
            .accessibilityLabel("Copy chart as PNG")

            Button {
                exportPNG()
            } label: {
                Label("Export PNG…", systemImage: "square.and.arrow.up")
            }
            .disabled(isWorking)
            .accessibilityLabel("Export chart as PNG file")

            if isWorking { ProgressView().controlSize(.small) }
            if let statusText {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func copyPNG() {
        isWorking = true
        statusText = nil
        let document = self.document
        let width = self.width
        let height = self.height
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try PlotPNGExporter().pngData(document: document, width: width, height: height)
                }.value
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
                statusText = "Copied PNG"
            } catch {
                statusText = "PNG copy failed"
            }
            isWorking = false
        }
    }

    private func exportPNG() {
        let panel = NSSavePanel()
        panel.title = "Export Chart as PNG"
        panel.nameFieldStringValue = suggestedFileName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isWorking = true
        statusText = nil
        let document = self.document
        let width = self.width
        let height = self.height
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let data = try PlotPNGExporter().pngData(document: document, width: width, height: height)
                    try data.write(to: url, options: .atomic)
                }.value
                statusText = "Exported \(url.lastPathComponent)"
            } catch {
                statusText = "PNG export failed"
            }
            isWorking = false
        }
    }
}

@available(macOS 13.0, *)
private struct PlotCursorReadout: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Text(line).font(.caption.monospacedDigit())
            }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.25)) }
        .accessibilityElement(children: .combine)
    }
}

@available(macOS 13.0, *)
@MainActor
private func plotNavigationButtons(
    zoomIn: @escaping () -> Void,
    zoomOut: @escaping () -> Void,
    reset: @escaping () -> Void
) -> some View {
    HStack(spacing: 4) {
        Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
            .help("Zoom in")
            .accessibilityLabel("Zoom plot in")
        Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
            .help("Zoom out")
            .accessibilityLabel("Zoom plot out")
        Button(action: reset) { Image(systemName: "arrow.counterclockwise") }
            .help("Reset viewport")
            .accessibilityLabel("Reset plot viewport")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
}

private struct PlotCanvasLayout {
    let size: CGSize
    let plotRect: CGRect

    init(size: CGSize) {
        self.size = size
        self.plotRect = CGRect(
            x: 56,
            y: 14,
            width: max(1, size.width - 70),
            height: max(1, size.height - 48)
        )
    }

    var topTrackRect: CGRect {
        CGRect(x: plotRect.minX, y: plotRect.minY, width: plotRect.width, height: plotRect.height / 2)
    }

    var bottomTrackRect: CGRect {
        CGRect(x: plotRect.minX, y: plotRect.midY, width: plotRect.width, height: plotRect.height / 2)
    }

    func normalizedX(for x: CGFloat) -> Double {
        min(1, max(0, Double((x - plotRect.minX) / max(1, plotRect.width))))
    }
}

private func drawScaffold(context: inout GraphicsContext, layout: PlotCanvasLayout) {
    var grid = Path()
    for step in 0...4 {
        let fraction = CGFloat(step) / 4
        let x = layout.plotRect.minX + layout.plotRect.width * fraction
        grid.move(to: CGPoint(x: x, y: layout.plotRect.minY))
        grid.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY))
        let y = layout.plotRect.minY + layout.plotRect.height * fraction
        grid.move(to: CGPoint(x: layout.plotRect.minX, y: y))
        grid.addLine(to: CGPoint(x: layout.plotRect.maxX, y: y))
    }
    context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
    context.stroke(Path(layout.plotRect), with: .color(.secondary.opacity(0.28)), lineWidth: 1)
}

private func drawWaveformTrack(
    _ track: WaveformTrackRenderData,
    viewport: PlotViewport,
    trackRect: CGRect,
    color: Color,
    context: inout GraphicsContext
) {
    var zero = Path()
    zero.move(to: CGPoint(x: trackRect.minX, y: trackRect.midY))
    zero.addLine(to: CGPoint(x: trackRect.maxX, y: trackRect.midY))
    context.stroke(zero, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
    var envelope = Path()
    for bin in track.bins {
        let x = plotX(bin.centerSamplePosition, viewport: viewport, rect: trackRect)
        envelope.move(to: CGPoint(x: x, y: amplitudeY(Double(bin.maximum), rect: trackRect)))
        envelope.addLine(to: CGPoint(x: x, y: amplitudeY(Double(bin.minimum), rect: trackRect)))
    }
    context.stroke(envelope, with: .color(color), lineWidth: 1)
}

private func drawWaveformMarkers(
    _ markers: [PlotMarker],
    viewport: PlotViewport,
    layout: PlotCanvasLayout,
    context: inout GraphicsContext
) {
    for marker in markers where marker.position >= viewport.visibleLowerBound && marker.position <= viewport.visibleUpperBound {
        let x = plotX(marker.position, viewport: viewport, rect: layout.plotRect)
        var path = Path()
        path.move(to: CGPoint(x: x, y: layout.plotRect.minY))
        path.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY))
        context.stroke(path, with: .color(.red.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        context.draw(
            Text(marker.label).font(.caption2).foregroundColor(.red),
            at: CGPoint(x: min(x + 50, layout.plotRect.maxX - 50), y: layout.plotRect.minY + 10)
        )
    }
}

private func drawTrackLabel(
    _ label: String,
    rect: CGRect,
    color: Color,
    context: inout GraphicsContext
) {
    context.draw(
        Text(label).font(.caption.bold()).foregroundColor(color),
        at: CGPoint(x: rect.minX + 36, y: rect.minY + 11)
    )
}

private func drawSampleTimeAxis(
    viewport: PlotViewport,
    sampleRate: Double,
    layout: PlotCanvasLayout,
    context: inout GraphicsContext
) {
    for step in 0...4 {
        let normalized = Double(step) / 4
        let sample = viewport.value(atNormalizedPosition: normalized)
        let seconds = sample / sampleRate
        let x = layout.plotRect.minX + layout.plotRect.width * CGFloat(normalized)
        context.draw(
            Text(String(format: "%.3fs\n%.0f smp", seconds, sample))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary),
            at: CGPoint(x: x, y: layout.plotRect.maxY + 20)
        )
    }
    context.draw(
        Text("+1\n0\n−1").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
        at: CGPoint(x: 24, y: layout.plotRect.midY)
    )
}

private func drawCorrelationEnvelope(
    _ data: CorrelationRenderData,
    layout: PlotCanvasLayout,
    context: inout GraphicsContext
) {
    var zero = Path()
    zero.move(to: CGPoint(x: layout.plotRect.minX, y: layout.plotRect.midY))
    zero.addLine(to: CGPoint(x: layout.plotRect.maxX, y: layout.plotRect.midY))
    context.stroke(zero, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
    var envelope = Path()
    for bin in data.bins {
        let x = plotX(Double(bin.strongestLag), viewport: data.viewport, rect: layout.plotRect)
        envelope.move(to: CGPoint(x: x, y: amplitudeY(Double(bin.maximum), rect: layout.plotRect)))
        envelope.addLine(to: CGPoint(x: x, y: amplitudeY(Double(bin.minimum), rect: layout.plotRect)))
    }
    context.stroke(envelope, with: .color(.purple), lineWidth: 1)
}

private func drawCorrelationThresholds(
    _ data: CorrelationRenderData,
    layout: PlotCanvasLayout,
    context: inout GraphicsContext
) {
    for sign in [-1.0, 1.0] {
        let y = amplitudeY(sign * data.confidenceThresholdMagnitude, rect: layout.plotRect)
        var threshold = Path()
        threshold.move(to: CGPoint(x: layout.plotRect.minX, y: y))
        threshold.addLine(to: CGPoint(x: layout.plotRect.maxX, y: y))
        context.stroke(threshold, with: .color(.yellow.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}

private func drawCorrelationMarkers(
    _ markers: [PlotMarker],
    viewport: PlotViewport,
    selectedPeakLag: Double?,
    layout: PlotCanvasLayout,
    context: inout GraphicsContext
) {
    for marker in markers where marker.kind != .confidenceThreshold
        && marker.position >= viewport.visibleLowerBound
        && marker.position <= viewport.visibleUpperBound {
        let x = plotX(marker.position, viewport: viewport, rect: layout.plotRect)
        let isSelected = selectedPeakLag.map { abs($0 - marker.position) < 0.001 } ?? false
        let color: Color
        switch marker.kind {
        case .primaryPeak: color = .red
        case .secondaryPeak: color = .orange
        case .candidatePeak: color = .mint
        case .searchBoundary: color = .secondary
        default: color = .purple
        }
        var line = Path()
        line.move(to: CGPoint(x: x, y: layout.plotRect.minY))
        line.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY))
        context.stroke(
            line,
            with: .color(color.opacity(isSelected ? 1 : 0.7)),
            style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1, dash: marker.kind == .searchBoundary ? [4, 3] : [])
        )
        if [.primaryPeak, .secondaryPeak, .candidatePeak].contains(marker.kind) {
            let y = amplitudeY(marker.value ?? 0, rect: layout.plotRect)
            context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)), with: .color(color))
        }
    }
}

private func drawCorrelationAxis(
    data: CorrelationRenderData,
    layout: PlotCanvasLayout,
    context: inout GraphicsContext
) {
    for step in 0...4 {
        let normalized = Double(step) / 4
        let lag = data.viewport.value(atNormalizedPosition: normalized)
        let x = layout.plotRect.minX + layout.plotRect.width * CGFloat(normalized)
        context.draw(
            Text(String(format: "%.0f smp\n%.3f ms", lag, data.milliseconds(forLag: lag)))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary),
            at: CGPoint(x: x, y: layout.plotRect.maxY + 20)
        )
    }
    context.draw(
        Text("+1\n0\n−1").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
        at: CGPoint(x: 24, y: layout.plotRect.midY)
    )
}

private func drawPeakDetail(
    _ data: PeakDetailRenderData,
    layout: PlotCanvasLayout,
    context: inout GraphicsContext
) {
    drawPointLine(data.samples, viewport: data.viewport, layout: layout, color: .purple, lineWidth: 1.5, context: &context)
    drawPointLine(data.interpolationCurve, viewport: data.viewport, layout: layout, color: .mint, lineWidth: 2.5, dashed: true, context: &context)

    for sign in [-1.0, 1.0] {
        let y = amplitudeY(sign * data.localNoiseFloor, rect: layout.plotRect)
        var noise = Path()
        noise.move(to: CGPoint(x: layout.plotRect.minX, y: y))
        noise.addLine(to: CGPoint(x: layout.plotRect.maxX, y: y))
        context.stroke(noise, with: .color(.yellow.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
    for marker in data.markers {
        let x = plotX(marker.position, viewport: data.viewport, rect: layout.plotRect)
        let color: Color = marker.kind == .fractionalPeak ? .mint : .red
        var line = Path()
        line.move(to: CGPoint(x: x, y: layout.plotRect.minY))
        line.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY))
        context.stroke(line, with: .color(color), lineWidth: 2)
    }
    if let width = data.peakWidthSamples {
        let center = data.fractionalPeakLag ?? Double(data.integerPeakLag)
        let x0 = plotX(center - width / 2, viewport: data.viewport, rect: layout.plotRect)
        let x1 = plotX(center + width / 2, viewport: data.viewport, rect: layout.plotRect)
        let y = layout.plotRect.maxY - 15
        var bracket = Path()
        bracket.move(to: CGPoint(x: x0, y: y))
        bracket.addLine(to: CGPoint(x: x1, y: y))
        context.stroke(bracket, with: .color(.secondary), lineWidth: 2)
        context.draw(
            Text(String(format: "width %.2f samples", width)).font(.caption2).foregroundColor(.secondary),
            at: CGPoint(x: (x0 + x1) / 2, y: y - 10)
        )
    }
}

private func drawPointLine(
    _ points: [PeakDetailPoint],
    viewport: PlotViewport,
    layout: PlotCanvasLayout,
    color: Color,
    lineWidth: CGFloat,
    dashed: Bool = false,
    context: inout GraphicsContext
) {
    guard let first = points.first else { return }
    var line = Path()
    line.move(to: CGPoint(x: plotX(first.lag, viewport: viewport, rect: layout.plotRect), y: amplitudeY(first.value, rect: layout.plotRect)))
    for point in points.dropFirst() {
        line.addLine(to: CGPoint(x: plotX(point.lag, viewport: viewport, rect: layout.plotRect), y: amplitudeY(point.value, rect: layout.plotRect)))
    }
    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, dash: dashed ? [5, 3] : []))
}

private func drawCursor(normalized: Double, layout: PlotCanvasLayout, context: inout GraphicsContext) {
    let x = layout.plotRect.minX + layout.plotRect.width * CGFloat(normalized)
    var cursor = Path()
    cursor.move(to: CGPoint(x: x, y: layout.plotRect.minY))
    cursor.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY))
    context.stroke(cursor, with: .color(.primary.opacity(0.65)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
}

private func plotX(_ value: Double, viewport: PlotViewport, rect: CGRect) -> CGFloat {
    rect.minX + rect.width * CGFloat(viewport.normalizedPosition(for: value))
}

private func amplitudeY(_ value: Double, rect: CGRect) -> CGFloat {
    rect.midY - CGFloat(min(1, max(-1, value))) * rect.height * 0.45
}
