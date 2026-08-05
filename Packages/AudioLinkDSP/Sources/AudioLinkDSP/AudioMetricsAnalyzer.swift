import Accelerate
import Foundation

public struct AudioMetricsAnalyzer: Sendable {
    public init() {}

    public func analyze(_ buffer: AudioSampleBuffer) -> AudioAnalysisMetrics {
        guard !buffer.samples.isEmpty else {
            return AudioAnalysisMetrics(
                peakMagnitude: 0,
                rootMeanSquare: 0,
                clippingSampleCount: 0,
                dcOffset: 0,
                channelDCOffsets: [Float](repeating: 0, count: buffer.channelCount)
            )
        }

        var offsets: [Float] = []
        offsets.reserveCapacity(buffer.channelCount)
        for channel in 0..<buffer.channelCount {
            let start = channel * buffer.frameCount
            var mean: Float = 0
            buffer.samples.withUnsafeBufferPointer { storage in
                guard let baseAddress = storage.baseAddress else { return }
                vDSP_meanv(
                    baseAddress.advanced(by: start),
                    1,
                    &mean,
                    vDSP_Length(buffer.frameCount)
                )
            }
            offsets.append(mean)
        }

        var overallMean: Float = 0
        vDSP_meanv(buffer.samples, 1, &overallMean, vDSP_Length(buffer.samples.count))
        let clippingThreshold: Float = 1 - 8 * Float.ulpOfOne
        let clippingCount = buffer.samples.reduce(into: 0) { count, sample in
            if abs(sample) >= clippingThreshold { count += 1 }
        }
        return AudioAnalysisMetrics(
            peakMagnitude: buffer.peakMagnitude,
            rootMeanSquare: buffer.rootMeanSquare,
            clippingSampleCount: clippingCount,
            dcOffset: overallMean,
            channelDCOffsets: offsets
        )
    }
}
