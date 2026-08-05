import Accelerate
import AudioLinkCore
@preconcurrency import AVFoundation
import Foundation

public struct AudioPreprocessor: Sendable {
    public init() {}

    public func process(
        _ importedFile: ImportedAudioFile,
        configuration: PreprocessingConfiguration,
        progress: AudioPreprocessingProgressHandler? = nil
    ) async throws -> ImportedAudioFile {
        if Task.isCancelled { throw AudioPreprocessingError.cancelled }
        let worker = Task.detached(priority: .userInitiated) {
            try Self.processSynchronously(
                importedFile,
                configuration: configuration,
                progress: progress
            )
        }
        return try await withTaskCancellationHandler {
            do {
                return try await worker.value
            } catch is CancellationError {
                throw AudioPreprocessingError.cancelled
            } catch let error as AudioPreprocessingError {
                throw error
            } catch {
                throw AudioPreprocessingError.conversionFailed(ErrorContext(error: error))
            }
        } onCancel: {
            worker.cancel()
        }
    }

    private static func processSynchronously(
        _ importedFile: ImportedAudioFile,
        configuration: PreprocessingConfiguration,
        progress: AudioPreprocessingProgressHandler?
    ) throws -> ImportedAudioFile {
        try validate(configuration, for: importedFile.audio)
        var audio = importedFile.audio
        var log = importedFile.preprocessingLog
        let operationCount = requestedOperationCount(configuration)
        var completedOperations = 0

        func reportProgress() {
            progress?(
                AudioPreprocessingProgress(
                    completedOperationCount: completedOperations,
                    totalOperationCount: operationCount
                )
            )
        }

        func appendLog(_ operation: PreprocessingOperation, inputFrames: Int, outputFrames: Int) {
            log.append(
                PreprocessingLogEntry(
                    sequence: log.count,
                    operation: operation,
                    inputFrameCount: inputFrames,
                    outputFrameCount: outputFrames
                )
            )
        }

        reportProgress()
        if let channel = configuration.selectedChannel {
            try checkCancellation()
            let inputFrames = audio.frameCount
            audio = try selectChannel(channel, from: audio)
            appendLog(.selectedChannel(index: channel), inputFrames: inputFrames, outputFrames: audio.frameCount)
            completedOperations += 1
            reportProgress()
        }
        if configuration.downmixToMono {
            try checkCancellation()
            let sourceChannels = audio.channelCount
            if sourceChannels > 1 {
                let inputFrames = audio.frameCount
                audio = try audio.convertedToMono()
                appendLog(
                    .downmixedToMono(sourceChannelCount: sourceChannels),
                    inputFrames: inputFrames,
                    outputFrames: audio.frameCount
                )
            }
            completedOperations += 1
            reportProgress()
        }
        if configuration.removeDCOffset {
            try checkCancellation()
            let inputFrames = audio.frameCount
            let result = try removingDCOffset(from: audio)
            audio = result.audio
            appendLog(
                .removedDCOffset(channelOffsets: result.offsets),
                inputFrames: inputFrames,
                outputFrames: audio.frameCount
            )
            completedOperations += 1
            reportProgress()
        }
        if let trim = configuration.trimLeadingSilence {
            try checkCancellation()
            let inputFrames = audio.frameCount
            let result = try trimmingLeadingSilence(in: audio, configuration: trim)
            audio = result.audio
            if result.trimmedFrames > 0 {
                appendLog(
                    .trimmedLeadingSilence(frames: result.trimmedFrames, threshold: trim.threshold),
                    inputFrames: inputFrames,
                    outputFrames: audio.frameCount
                )
            }
            completedOperations += 1
            reportProgress()
        }
        if let trim = configuration.trimTrailingSilence {
            try checkCancellation()
            let inputFrames = audio.frameCount
            let result = try trimmingTrailingSilence(in: audio, configuration: trim)
            audio = result.audio
            if result.trimmedFrames > 0 {
                appendLog(
                    .trimmedTrailingSilence(frames: result.trimmedFrames, threshold: trim.threshold),
                    inputFrames: inputFrames,
                    outputFrames: audio.frameCount
                )
            }
            completedOperations += 1
            reportProgress()
        }
        if let highPass = configuration.highPassFilter {
            try checkCancellation()
            let inputFrames = audio.frameCount
            audio = try applyingHighPassFilter(
                to: audio,
                cutoffFrequencyHertz: highPass.cutoffFrequencyHertz
            )
            appendLog(
                .highPassFiltered(cutoffFrequencyHertz: highPass.cutoffFrequencyHertz),
                inputFrames: inputFrames,
                outputFrames: audio.frameCount
            )
            completedOperations += 1
            reportProgress()
        }
        if let targetSampleRate = configuration.targetSampleRate {
            try checkCancellation()
            if targetSampleRate != audio.format.sampleRate {
                let sourceRate = audio.format.sampleRate
                let inputFrames = audio.frameCount
                audio = try AppleAudioResampler.resample(audio, to: targetSampleRate)
                appendLog(
                    .resampled(
                        sourceSampleRate: sourceRate,
                        destinationSampleRate: targetSampleRate,
                        inputFrames: inputFrames,
                        outputFrames: audio.frameCount
                    ),
                    inputFrames: inputFrames,
                    outputFrames: audio.frameCount
                )
            }
            completedOperations += 1
            reportProgress()
        }
        if configuration.invertPolarity {
            try checkCancellation()
            let inputFrames = audio.frameCount
            audio = try audio.applyingGain(-1)
            appendLog(.invertedPolarity, inputFrames: inputFrames, outputFrames: audio.frameCount)
            completedOperations += 1
            reportProgress()
        }
        if let gain = configuration.gain {
            try checkCancellation()
            try validateSafeGain(gain, for: audio, operation: "gain")
            let inputFrames = audio.frameCount
            audio = try audio.applyingGain(gain)
            appendLog(.appliedGain(gain: gain), inputFrames: inputFrames, outputFrames: audio.frameCount)
            completedOperations += 1
            reportProgress()
        }
        if let target = configuration.peakNormalizationTarget {
            try checkCancellation()
            let currentPeak = audio.peakMagnitude
            let appliedGain: Float
            if target == 0 {
                appliedGain = 0
            } else {
                guard currentPeak > 0 else { throw AudioPreprocessingError.silentAudioCannotBeNormalized }
                appliedGain = target / currentPeak
            }
            let inputFrames = audio.frameCount
            audio = try audio.applyingGain(appliedGain)
            appendLog(
                .peakNormalized(target: target, appliedGain: appliedGain),
                inputFrames: inputFrames,
                outputFrames: audio.frameCount
            )
            completedOperations += 1
            reportProgress()
        }
        if let target = configuration.rmsNormalizationTarget {
            try checkCancellation()
            let currentRMS = audio.rootMeanSquare
            let appliedGain: Float
            if target == 0 {
                appliedGain = 0
            } else {
                guard currentRMS > 0 else { throw AudioPreprocessingError.silentAudioCannotBeNormalized }
                appliedGain = target / currentRMS
            }
            try validateSafeGain(appliedGain, for: audio, operation: "RMS normalization")
            let inputFrames = audio.frameCount
            audio = try audio.applyingGain(appliedGain)
            appendLog(
                .rmsNormalized(target: target, appliedGain: appliedGain),
                inputFrames: inputFrames,
                outputFrames: audio.frameCount
            )
            completedOperations += 1
            reportProgress()
        }

        try checkCancellation()
        return ImportedAudioFile(
            fileURL: importedFile.fileURL,
            fileName: importedFile.fileName,
            originalFormat: importedFile.originalFormat,
            audio: audio,
            analysis: AudioMetricsAnalyzer().analyze(audio),
            metadata: importedFile.metadata,
            preprocessingLog: log
        )
    }

    private static func validate(
        _ configuration: PreprocessingConfiguration,
        for audio: AudioSampleBuffer
    ) throws {
        if configuration.selectedChannel != nil, configuration.downmixToMono {
            throw AudioPreprocessingError.conflictingChannelOperations
        }
        if configuration.peakNormalizationTarget != nil,
           configuration.rmsNormalizationTarget != nil {
            throw AudioPreprocessingError.conflictingNormalizations
        }
        if let channel = configuration.selectedChannel,
           !(0..<audio.channelCount).contains(channel) {
            throw AudioPreprocessingError.invalidChannelSelection(
                requested: channel,
                available: audio.channelCount
            )
        }
        for trim in [configuration.trimLeadingSilence, configuration.trimTrailingSilence].compactMap({ $0 }) {
            guard trim.threshold.isFinite, (0...1).contains(trim.threshold) else {
                throw AudioPreprocessingError.invalidSilenceThreshold(trim.threshold)
            }
        }
        if let filter = configuration.highPassFilter {
            let nyquist = audio.format.sampleRate.hertz / 2
            guard filter.cutoffFrequencyHertz.isFinite,
                  filter.cutoffFrequencyHertz > 0,
                  filter.cutoffFrequencyHertz < nyquist else {
                throw AudioPreprocessingError.invalidHighPassCutoff(
                    value: filter.cutoffFrequencyHertz,
                    nyquist: nyquist
                )
            }
        }
        if let gain = configuration.gain,
           (!gain.isFinite || gain < 0) {
            throw AudioPreprocessingError.invalidGain(gain)
        }
        for target in [
            configuration.peakNormalizationTarget,
            configuration.rmsNormalizationTarget
        ].compactMap({ $0 }) {
            guard target.isFinite, (0...1).contains(target) else {
                throw AudioPreprocessingError.invalidNormalizationTarget(target)
            }
        }
    }

    private static func requestedOperationCount(_ configuration: PreprocessingConfiguration) -> Int {
        [
            configuration.selectedChannel != nil,
            configuration.downmixToMono,
            configuration.removeDCOffset,
            configuration.trimLeadingSilence != nil,
            configuration.trimTrailingSilence != nil,
            configuration.highPassFilter != nil,
            configuration.targetSampleRate != nil,
            configuration.invertPolarity,
            configuration.gain != nil,
            configuration.peakNormalizationTarget != nil,
            configuration.rmsNormalizationTarget != nil
        ].filter { $0 }.count
    }

    private static func selectChannel(
        _ channel: Int,
        from audio: AudioSampleBuffer
    ) throws -> AudioSampleBuffer {
        let start = channel * audio.frameCount
        return try AudioSampleBuffer(
            samples: Array(audio.samples[start..<(start + audio.frameCount)]),
            format: AudioFormatDescriptor(
                sampleRate: audio.format.sampleRate,
                channelCount: 1,
                bitDepth: 32,
                isInterleaved: false
            )
        )
    }

    private static func removingDCOffset(
        from audio: AudioSampleBuffer
    ) throws -> (audio: AudioSampleBuffer, offsets: [Float]) {
        guard audio.frameCount > 0 else {
            return (audio, [Float](repeating: 0, count: audio.channelCount))
        }
        var samples = audio.samples
        var offsets: [Float] = []
        offsets.reserveCapacity(audio.channelCount)
        for channel in 0..<audio.channelCount {
            try checkCancellation()
            let start = channel * audio.frameCount
            var mean: Float = 0
            samples.withUnsafeBufferPointer { storage in
                guard let baseAddress = storage.baseAddress else { return }
                vDSP_meanv(
                    baseAddress.advanced(by: start),
                    1,
                    &mean,
                    vDSP_Length(audio.frameCount)
                )
            }
            offsets.append(mean)
            var adjustment = -mean
            samples.withUnsafeMutableBufferPointer { storage in
                guard let baseAddress = storage.baseAddress else { return }
                vDSP_vsadd(
                    baseAddress.advanced(by: start),
                    1,
                    &adjustment,
                    baseAddress.advanced(by: start),
                    1,
                    vDSP_Length(audio.frameCount)
                )
            }
        }
        return (try AudioSampleBuffer(samples: samples, format: audio.format), offsets)
    }

    private static func trimmingLeadingSilence(
        in audio: AudioSampleBuffer,
        configuration: SilenceTrimmingConfiguration
    ) throws -> (audio: AudioSampleBuffer, trimmedFrames: Int) {
        var firstSignalFrame = audio.frameCount
        for frame in 0..<audio.frameCount {
            if frame.isMultiple(of: 8_192) { try checkCancellation() }
            if frameContainsSignal(frame, in: audio, threshold: configuration.threshold) {
                firstSignalFrame = frame
                break
            }
        }
        let minimumFrames = safeFrameCount(
            duration: configuration.minimumSilenceDuration,
            sampleRate: audio.format.sampleRate
        )
        guard firstSignalFrame >= minimumFrames else { return (audio, 0) }
        return (try slice(audio, frames: firstSignalFrame..<audio.frameCount), firstSignalFrame)
    }

    private static func trimmingTrailingSilence(
        in audio: AudioSampleBuffer,
        configuration: SilenceTrimmingConfiguration
    ) throws -> (audio: AudioSampleBuffer, trimmedFrames: Int) {
        var lastSignalFrame = -1
        if audio.frameCount > 0 {
            for frame in stride(from: audio.frameCount - 1, through: 0, by: -1) {
                if frame.isMultiple(of: 8_192) { try checkCancellation() }
                if frameContainsSignal(frame, in: audio, threshold: configuration.threshold) {
                    lastSignalFrame = frame
                    break
                }
            }
        }
        let trimmedFrames = audio.frameCount - (lastSignalFrame + 1)
        let minimumFrames = safeFrameCount(
            duration: configuration.minimumSilenceDuration,
            sampleRate: audio.format.sampleRate
        )
        guard trimmedFrames >= minimumFrames else { return (audio, 0) }
        return (try slice(audio, frames: 0..<(lastSignalFrame + 1)), trimmedFrames)
    }

    private static func frameContainsSignal(
        _ frame: Int,
        in audio: AudioSampleBuffer,
        threshold: Float
    ) -> Bool {
        for channel in 0..<audio.channelCount {
            if abs(audio.samples[channel * audio.frameCount + frame]) > threshold { return true }
        }
        return false
    }

    private static func slice(
        _ audio: AudioSampleBuffer,
        frames: Range<Int>
    ) throws -> AudioSampleBuffer {
        guard frames.lowerBound != 0 || frames.upperBound != audio.frameCount else { return audio }
        var samples: [Float] = []
        let (sampleCount, overflow) = frames.count.multipliedReportingOverflow(by: audio.channelCount)
        guard !overflow else { throw AudioSampleBufferError.sampleCountOverflow }
        samples.reserveCapacity(sampleCount)
        for channel in 0..<audio.channelCount {
            let channelStart = channel * audio.frameCount
            samples.append(
                contentsOf: audio.samples[
                    (channelStart + frames.lowerBound)..<(channelStart + frames.upperBound)
                ]
            )
        }
        return try AudioSampleBuffer(samples: samples, format: audio.format)
    }

    private static func applyingHighPassFilter(
        to audio: AudioSampleBuffer,
        cutoffFrequencyHertz: Double
    ) throws -> AudioSampleBuffer {
        guard audio.frameCount > 0 else { return audio }
        let sampleRate = audio.format.sampleRate.hertz
        let k = tan(Double.pi * cutoffFrequencyHertz / sampleRate)
        let rootTwo = sqrt(2.0)
        let normalization = 1 / (1 + rootTwo * k + k * k)
        let b0 = normalization
        let b1 = -2 * normalization
        let b2 = normalization
        let a1 = 2 * (k * k - 1) * normalization
        let a2 = (1 - rootTwo * k + k * k) * normalization
        var output = [Float](repeating: 0, count: audio.samples.count)

        for channel in 0..<audio.channelCount {
            var x1 = 0.0
            var x2 = 0.0
            var y1 = 0.0
            var y2 = 0.0
            let channelStart = channel * audio.frameCount
            for frame in 0..<audio.frameCount {
                if frame.isMultiple(of: 8_192) { try checkCancellation() }
                let x0 = Double(audio.samples[channelStart + frame])
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                output[channelStart + frame] = Float(y0)
                x2 = x1
                x1 = x0
                y2 = y1
                y1 = y0
            }
        }
        return try AudioSampleBuffer(samples: output, format: audio.format)
    }

    private static func validateSafeGain(
        _ gain: Float,
        for audio: AudioSampleBuffer,
        operation: String
    ) throws {
        guard gain.isFinite, gain >= 0 else { throw AudioPreprocessingError.invalidGain(gain) }
        let resultingPeak = audio.peakMagnitude * gain
        guard resultingPeak.isFinite, resultingPeak <= 1 + 8 * Float.ulpOfOne else {
            throw AudioPreprocessingError.operationWouldClip(
                operation: operation,
                resultingPeak: resultingPeak
            )
        }
    }

    private static func safeFrameCount(
        duration: DurationSeconds,
        sampleRate: SampleRate
    ) -> Int {
        let value = (duration.value * sampleRate.hertz).rounded()
        guard value.isFinite, value > 0, value < Double(Int.max) else { return 0 }
        return Int(value)
    }

    fileprivate static func checkCancellation() throws {
        if Task.isCancelled { throw AudioPreprocessingError.cancelled }
    }
}

private enum AppleAudioResampler {
    static func resample(
        _ source: AudioSampleBuffer,
        to targetSampleRate: SampleRate
    ) throws -> AudioSampleBuffer {
        guard source.frameCount > 0 else {
            return try AudioSampleBuffer(
                samples: [],
                format: AudioFormatDescriptor(
                    sampleRate: targetSampleRate,
                    channelCount: source.channelCount,
                    bitDepth: 32,
                    isInterleaved: false
                )
            )
        }
        guard source.frameCount <= Int(AVAudioFrameCount.max) else {
            throw AudioPreprocessingError.conversionFailed(
                ErrorContext(diagnosticMessage: "Input exceeds AVAudioPCMBuffer frame capacity.")
            )
        }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.format.sampleRate.hertz,
            channels: AVAudioChannelCount(source.channelCount),
            interleaved: false
        ),
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate.hertz,
            channels: AVAudioChannelCount(source.channelCount),
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(source.frameCount)
        ) else {
            throw AudioPreprocessingError.conversionFailed(
                ErrorContext(diagnosticMessage: "AVFoundation could not create the sample-rate converter.")
            )
        }
        inputBuffer.frameLength = AVAudioFrameCount(source.frameCount)
        guard let inputChannels = inputBuffer.floatChannelData else {
            throw AudioPreprocessingError.conversionFailed(
                ErrorContext(diagnosticMessage: "AVFoundation did not expose Float input channels.")
            )
        }
        for channel in 0..<source.channelCount {
            let sourceStart = channel * source.frameCount
            for frame in 0..<source.frameCount {
                inputChannels[channel][frame] = source.samples[sourceStart + frame]
            }
        }

        let exactOutputFrames = Double(source.frameCount) *
            targetSampleRate.hertz / source.format.sampleRate.hertz
        let expectedOutputFrames = Int(exactOutputFrames.rounded())
        // Constrain the converter to the mathematically expected timeline.
        // A larger buffer allows AVAudioConverter to emit filter-tail frames,
        // which are useful for effects but would lengthen a delay reference.
        let capacityFrames = expectedOutputFrames
        guard capacityFrames > 0,
              capacityFrames <= Int(AVAudioFrameCount.max),
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(capacityFrames)
              ) else {
            throw AudioPreprocessingError.conversionFailed(
                ErrorContext(diagnosticMessage: "Resampled output exceeds AVAudioPCMBuffer capacity.")
            )
        }
        converter.primeMethod = .none
        let inputProvider = ConverterInputProvider(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        guard status != .error, conversionError == nil else {
            throw AudioPreprocessingError.conversionFailed(
                conversionError.map { ErrorContext(error: $0) } ??
                    ErrorContext(diagnosticMessage: "AVAudioConverter returned an error status.")
            )
        }
        try AudioPreprocessor.checkCancellation()
        let converted: AudioSampleBuffer
        do {
            converted = try AudioSampleBuffer(pcmBuffer: outputBuffer)
        } catch {
            throw AudioPreprocessingError.conversionFailed(ErrorContext(error: error))
        }
        let sourceDuration = Double(source.frameCount) / source.format.sampleRate.hertz
        let outputDuration = Double(converted.frameCount) / targetSampleRate.hertz
        let maximumDurationError = 1 / targetSampleRate.hertz
        guard abs(sourceDuration - outputDuration) <= maximumDurationError + Double.ulpOfOne else {
            throw AudioPreprocessingError.conversionFailed(
                ErrorContext(
                    diagnosticMessage: "Sample-rate conversion duration error exceeds one output frame.",
                    metadata: [
                        "inputFrames": String(source.frameCount),
                        "expectedOutputFrames": String(expectedOutputFrames),
                        "actualOutputFrames": String(converted.frameCount)
                    ]
                )
            )
        }
        return converted
    }
}

/// AVAudioConverter's input closure is imported as @Sendable even though the
/// converter invokes it serially. This locked owner makes that contract
/// explicit and confines the non-Sendable AVAudioPCMBuffer to the conversion.
private final class ConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var hasSuppliedBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if hasSuppliedBuffer {
            status.pointee = .endOfStream
            return nil
        }
        hasSuppliedBuffer = true
        status.pointee = .haveData
        return buffer
    }
}
