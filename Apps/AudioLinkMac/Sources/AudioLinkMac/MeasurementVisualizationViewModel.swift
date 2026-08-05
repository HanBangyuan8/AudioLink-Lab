import AudioLinkDSP
import Combine
import Foundation

@MainActor
final class MeasurementVisualizationViewModel: ObservableObject {
    @Published private(set) var waveformData: WaveformRenderData?
    @Published private(set) var correlationData: CorrelationRenderData?
    @Published private(set) var peakDetailData: PeakDetailRenderData?
    @Published private(set) var isPreparingWaveform = false
    @Published private(set) var isPreparingCorrelation = false
    @Published private(set) var preparationError: String?
    @Published private(set) var selectedPeakLag: Double?
    @Published private(set) var alignmentMode = WaveformAlignmentMode.unaligned
    @Published private(set) var waveformViewport: PlotViewport
    @Published private(set) var correlationViewport: PlotViewport

    private let renderer: MeasurementVisualizationRenderer
    private var waveformTask: Task<Void, Never>?
    private var correlationTask: Task<Void, Never>?
    private var peakTask: Task<Void, Never>?
    private var waveformGeneration: UInt64 = 0
    private var correlationGeneration: UInt64 = 0
    private var pixelWidth = 1_000

    init(analysis: NewMeasurementAnalysis) {
        let renderer = MeasurementVisualizationRenderer(analysis: analysis)
        self.renderer = renderer
        self.waveformViewport = renderer.initialWaveformViewport(alignment: .unaligned)
        self.correlationViewport = renderer.initialCorrelationViewport()
        self.selectedPeakLag = analysis.assessment.correlation?.primaryPeak.map {
            $0.fractionalLag ?? Double($0.lag.rawValue)
        }
    }

    deinit {
        waveformTask?.cancel()
        correlationTask?.cancel()
        peakTask?.cancel()
    }

    func prepare(pixelWidth: Int) {
        self.pixelWidth = max(1, pixelWidth)
        scheduleWaveformPreparation()
        scheduleCorrelationPreparation()
        schedulePeakPreparation()
    }

    func setAlignment(_ alignment: WaveformAlignmentMode) {
        guard alignmentMode != alignment else { return }
        alignmentMode = alignment
        waveformViewport = renderer.initialWaveformViewport(alignment: alignment)
        scheduleWaveformPreparation()
    }

    func zoomWaveform(by factor: Double, anchorNormalized: Double) {
        waveformViewport = waveformViewport.zoomed(by: factor, anchorNormalized: anchorNormalized)
        scheduleWaveformPreparation()
    }

    func panWaveform(by deltaSamples: Double) {
        waveformViewport = waveformViewport.panned(by: deltaSamples)
        scheduleWaveformPreparation()
    }

    func resetWaveformViewport() {
        waveformViewport = renderer.initialWaveformViewport(alignment: alignmentMode)
        scheduleWaveformPreparation()
    }

    func zoomCorrelation(by factor: Double, anchorNormalized: Double) {
        correlationViewport = correlationViewport.zoomed(by: factor, anchorNormalized: anchorNormalized)
        scheduleCorrelationPreparation()
    }

    func panCorrelation(by deltaSamples: Double) {
        correlationViewport = correlationViewport.panned(by: deltaSamples)
        scheduleCorrelationPreparation()
    }

    func resetCorrelationViewport() {
        correlationViewport = renderer.initialCorrelationViewport()
        scheduleCorrelationPreparation()
    }

    func selectPeak(nearestTo lag: Double) {
        let peakMarkers = correlationData?.markers.filter {
            [.primaryPeak, .secondaryPeak, .candidatePeak].contains($0.kind)
        } ?? []
        guard let nearest = peakMarkers.min(by: {
            abs($0.position - lag) < abs($1.position - lag)
        }) else { return }
        selectedPeakLag = nearest.position
        schedulePeakPreparation()
    }

    private func scheduleWaveformPreparation() {
        waveformGeneration &+= 1
        let generation = waveformGeneration
        waveformTask?.cancel()
        isPreparingWaveform = true
        preparationError = nil
        let renderer = self.renderer
        let viewport = waveformViewport
        let alignment = alignmentMode
        let width = pixelWidth
        waveformTask = Task { [weak self] in
            do {
                let data = try await renderer.waveform(
                    viewport: viewport,
                    alignment: alignment,
                    pixelWidth: width
                )
                try Task.checkCancellation()
                guard let self, self.waveformGeneration == generation else { return }
                self.waveformData = data
                self.isPreparingWaveform = false
            } catch is CancellationError {
                guard let self, self.waveformGeneration == generation else { return }
                self.isPreparingWaveform = false
            } catch {
                guard let self, self.waveformGeneration == generation else { return }
                self.isPreparingWaveform = false
                self.preparationError = "Waveform display data could not be prepared."
            }
        }
    }

    private func scheduleCorrelationPreparation() {
        correlationGeneration &+= 1
        let generation = correlationGeneration
        correlationTask?.cancel()
        isPreparingCorrelation = true
        preparationError = nil
        let renderer = self.renderer
        let viewport = correlationViewport
        let width = pixelWidth
        correlationTask = Task { [weak self] in
            do {
                let data = try await renderer.correlation(viewport: viewport, pixelWidth: width)
                try Task.checkCancellation()
                guard let self, self.correlationGeneration == generation else { return }
                self.correlationData = data
                self.isPreparingCorrelation = false
            } catch is CancellationError {
                guard let self, self.correlationGeneration == generation else { return }
                self.isPreparingCorrelation = false
            } catch {
                guard let self, self.correlationGeneration == generation else { return }
                self.isPreparingCorrelation = false
                self.preparationError = "Correlation display data could not be prepared."
            }
        }
    }

    private func schedulePeakPreparation() {
        peakTask?.cancel()
        let renderer = self.renderer
        let selectedPeakLag = self.selectedPeakLag
        peakTask = Task { [weak self] in
            do {
                let data = try await renderer.peakDetail(selectedLag: selectedPeakLag)
                try Task.checkCancellation()
                guard let self else { return }
                self.peakDetailData = data
            } catch {
                guard !(error is CancellationError), let self else { return }
                self.preparationError = "Peak-detail display data could not be prepared."
            }
        }
    }
}
