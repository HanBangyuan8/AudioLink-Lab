import Accelerate
import AudioLinkCore
import AudioToolbox
import AVFoundation
import Foundation

public enum AudioSampleBufferError: Error, Equatable, Sendable {
    case invalidChannelCount(Int)
    case invalidChannelIndex(requested: Int, available: Int)
    case unsupportedFormat(bitDepth: Int, isInterleaved: Bool)
    case inconsistentSampleStorage(sampleCount: Int, channelCount: Int)
    case nonFiniteSample(index: Int)
    case invalidGain(Float)
    case invalidTargetPeak(Float)
    case invalidFade(frameCount: Int, fadeInFrames: Int, fadeOutFrames: Int)
    case invalidSilenceFrameCount(Int)
    case sampleCountOverflow
    case unsupportedChannelConversion(source: Int, destination: Int)
}

extension AudioSampleBufferError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidChannelCount:
            "Channel count must be greater than zero."
        case .invalidChannelIndex:
            "The requested channel index is outside the PCM buffer."
        case .unsupportedFormat:
            "AudioSampleBuffer requires planar, normalized Float32 PCM."
        case .inconsistentSampleStorage:
            "Planar sample storage does not contain the same number of frames for every channel."
        case .nonFiniteSample:
            "PCM data contains NaN or infinity."
        case .invalidGain:
            "Gain must be finite and must not overflow Float PCM."
        case .invalidTargetPeak:
            "Normalization target must be finite and between zero and one."
        case .invalidFade:
            "Fade lengths must fit inside the buffer without overlapping."
        case .invalidSilenceFrameCount:
            "Silence frame count must not be negative."
        case .sampleCountOverflow:
            "The requested PCM buffer is too large."
        case .unsupportedChannelConversion:
            "Only mono and stereo conversion is currently supported."
        }
    }
}

/// Canonical in-memory PCM representation used by AudioLinkDSP.
///
/// Samples are normalized Float32 values stored in non-interleaved, planar
/// order: all frames for channel 0, followed by all frames for channel 1, etc.
/// Swift Array copy-on-write storage lets value copies share their sample memory
/// until one copy is mutated.
public struct AudioSampleBuffer: Equatable, Sendable {
    public private(set) var samples: [Float]
    public let format: AudioFormatDescriptor

    public init(samples: [Float], format: AudioFormatDescriptor) throws {
        guard format.channelCount > 0 else {
            throw AudioSampleBufferError.invalidChannelCount(format.channelCount)
        }
        guard format.bitDepth == 32, !format.isInterleaved else {
            throw AudioSampleBufferError.unsupportedFormat(
                bitDepth: format.bitDepth,
                isInterleaved: format.isInterleaved
            )
        }
        guard samples.count.isMultiple(of: format.channelCount) else {
            throw AudioSampleBufferError.inconsistentSampleStorage(
                sampleCount: samples.count,
                channelCount: format.channelCount
            )
        }
        if let invalidIndex = samples.firstIndex(where: { !$0.isFinite }) {
            throw AudioSampleBufferError.nonFiniteSample(index: invalidIndex)
        }

        self.samples = samples
        self.format = format
    }

    public init(pcmBuffer: AVAudioPCMBuffer) throws {
        guard pcmBuffer.format.commonFormat == .pcmFormatFloat32,
              !pcmBuffer.format.isInterleaved,
              let channels = pcmBuffer.floatChannelData,
              pcmBuffer.format.channelCount > 0 else {
            throw AudioSampleBufferError.unsupportedFormat(
                bitDepth: Int(pcmBuffer.format.streamDescription.pointee.mBitsPerChannel),
                isInterleaved: pcmBuffer.format.isInterleaved
            )
        }

        let frameCount = Int(pcmBuffer.frameLength)
        let channelCount = Int(pcmBuffer.format.channelCount)
        let (sampleCount, overflow) = frameCount.multipliedReportingOverflow(by: channelCount)
        guard !overflow else { throw AudioSampleBufferError.sampleCountOverflow }
        var planarSamples: [Float] = []
        planarSamples.reserveCapacity(sampleCount)
        for channel in 0..<channelCount {
            planarSamples.append(contentsOf: UnsafeBufferPointer(start: channels[channel], count: frameCount))
        }

        try self.init(
            samples: planarSamples,
            format: AudioFormatDescriptor(
                sampleRate: try SampleRate(hertz: pcmBuffer.format.sampleRate),
                channelCount: channelCount,
                bitDepth: 32,
                isInterleaved: false
            )
        )
    }

    public var frameCount: Int { samples.count / format.channelCount }
    public var channelCount: Int { format.channelCount }
    public var sampleCount: SampleCount { SampleCount(rawValue: Int64(frameCount)) }
    public var duration: DurationSeconds { sampleCount.duration(at: format.sampleRate) }
    public var isPlanar: Bool { !format.isInterleaved }

    public var peakMagnitude: Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak
    }

    public var rootMeanSquare: Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    public func withUnsafeSamples<Result>(
        _ body: (UnsafeBufferPointer<Float>) throws -> Result
    ) rethrows -> Result {
        try samples.withUnsafeBufferPointer(body)
    }

    public func withUnsafeChannelSamples<Result>(
        channel: Int,
        _ body: (UnsafeBufferPointer<Float>) throws -> Result
    ) throws -> Result {
        guard (0..<channelCount).contains(channel) else {
            throw AudioSampleBufferError.invalidChannelIndex(
                requested: channel,
                available: channelCount
            )
        }
        let bounds = (channel * frameCount)..<((channel + 1) * frameCount)
        return try samples.withUnsafeBufferPointer { storage in
            try body(UnsafeBufferPointer(rebasing: storage[bounds]))
        }
    }

    public func sample(frame: Int, channel: Int) -> Float? {
        guard (0..<frameCount).contains(frame), (0..<channelCount).contains(channel) else {
            return nil
        }
        return samples[channel * frameCount + frame]
    }

    public mutating func applyGain(_ gain: Float) throws {
        let peak = peakMagnitude
        guard gain.isFinite,
              peak == 0 || Double(peak) * abs(Double(gain)) <= Double(Float.greatestFiniteMagnitude) else {
            throw AudioSampleBufferError.invalidGain(gain)
        }
        guard !samples.isEmpty else { return }

        var scalar = gain
        samples.withUnsafeMutableBufferPointer { storage in
            guard let baseAddress = storage.baseAddress else { return }
            vDSP_vsmul(
                baseAddress,
                1,
                &scalar,
                baseAddress,
                1,
                vDSP_Length(storage.count)
            )
        }
    }

    public func applyingGain(_ gain: Float) throws -> Self {
        var result = self
        try result.applyGain(gain)
        return result
    }

    public mutating func normalize(toPeak targetPeak: Float = 1) throws {
        guard targetPeak.isFinite, (0...1).contains(targetPeak) else {
            throw AudioSampleBufferError.invalidTargetPeak(targetPeak)
        }
        let currentPeak = peakMagnitude
        guard currentPeak > 0 else { return }
        try applyGain(targetPeak / currentPeak)
    }

    public func normalized(toPeak targetPeak: Float = 1) throws -> Self {
        var result = self
        try result.normalize(toPeak: targetPeak)
        return result
    }

    /// Applies raised-cosine fades. The first fade-in sample and last fade-out
    /// sample are exactly zero; their opposite endpoints are exactly one.
    public mutating func applyFades(fadeInFrames: Int, fadeOutFrames: Int) throws {
        guard fadeInFrames >= 0,
              fadeOutFrames >= 0,
              fadeInFrames <= frameCount,
              fadeOutFrames <= frameCount,
              fadeInFrames + fadeOutFrames <= frameCount else {
            throw AudioSampleBufferError.invalidFade(
                frameCount: frameCount,
                fadeInFrames: fadeInFrames,
                fadeOutFrames: fadeOutFrames
            )
        }

        for channel in 0..<channelCount {
            let channelOffset = channel * frameCount
            for frame in 0..<fadeInFrames {
                let gain: Float
                if fadeInFrames == 1 {
                    gain = 0
                } else {
                    gain = Float(0.5 - 0.5 * cos(Double.pi * Double(frame) / Double(fadeInFrames - 1)))
                }
                samples[channelOffset + frame] *= gain
            }
            for offset in 0..<fadeOutFrames {
                let frame = frameCount - fadeOutFrames + offset
                let gain: Float
                if fadeOutFrames == 1 {
                    gain = 0
                } else {
                    gain = Float(0.5 + 0.5 * cos(Double.pi * Double(offset) / Double(fadeOutFrames - 1)))
                }
                samples[channelOffset + frame] *= gain
            }
        }
    }

    public func applyingFades(fadeInFrames: Int, fadeOutFrames: Int) throws -> Self {
        var result = self
        try result.applyFades(fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames)
        return result
    }

    public func addingSilence(preFrames: Int, postFrames: Int) throws -> Self {
        guard preFrames >= 0 else {
            throw AudioSampleBufferError.invalidSilenceFrameCount(preFrames)
        }
        guard postFrames >= 0 else {
            throw AudioSampleBufferError.invalidSilenceFrameCount(postFrames)
        }
        guard preFrames != 0 || postFrames != 0 else { return self }
        let (paddedFrameCount, frameOverflow) = frameCount.addingReportingOverflow(preFrames)
        let (totalFrameCount, postOverflow) = paddedFrameCount.addingReportingOverflow(postFrames)
        let (totalSampleCount, sampleOverflow) = totalFrameCount.multipliedReportingOverflow(by: channelCount)
        guard !frameOverflow, !postOverflow, !sampleOverflow else {
            throw AudioSampleBufferError.sampleCountOverflow
        }

        var padded = [Float](repeating: 0, count: totalSampleCount)
        for channel in 0..<channelCount {
            let sourceStart = channel * frameCount
            let destinationStart = channel * totalFrameCount + preFrames
            padded.replaceSubrange(
                destinationStart..<(destinationStart + frameCount),
                with: samples[sourceStart..<(sourceStart + frameCount)]
            )
        }
        return try Self(samples: padded, format: format)
    }

    public func convertedToMono() throws -> Self {
        guard channelCount != 1 else { return self }
        guard channelCount == 2 else {
            throw AudioSampleBufferError.unsupportedChannelConversion(source: channelCount, destination: 1)
        }

        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            mono[frame] = (samples[frame] + samples[frameCount + frame]) * 0.5
        }
        return try Self(
            samples: mono,
            format: AudioFormatDescriptor(
                sampleRate: format.sampleRate,
                channelCount: 1,
                bitDepth: 32,
                isInterleaved: false
            )
        )
    }

    public func convertedToStereo() throws -> Self {
        guard channelCount != 2 else { return self }
        guard channelCount == 1 else {
            throw AudioSampleBufferError.unsupportedChannelConversion(source: channelCount, destination: 2)
        }

        let (stereoSampleCount, overflow) = samples.count.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw AudioSampleBufferError.sampleCountOverflow }
        var stereo = [Float]()
        stereo.reserveCapacity(stereoSampleCount)
        stereo.append(contentsOf: samples)
        stereo.append(contentsOf: samples)
        return try Self(
            samples: stereo,
            format: AudioFormatDescriptor(
                sampleRate: format.sampleRate,
                channelCount: 2,
                bitDepth: 32,
                isInterleaved: false
            )
        )
    }
}
