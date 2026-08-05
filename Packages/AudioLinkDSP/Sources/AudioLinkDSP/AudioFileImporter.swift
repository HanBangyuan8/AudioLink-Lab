import AudioLinkCore
import AudioToolbox
import AVFoundation
import Foundation

public struct AudioImportLimits: Codable, Equatable, Sendable {
    public static let `default` = AudioImportLimits(maximumDecodedFrames: 50_000_000, maximumDecodedBytes: 1_000_000_000)
    public let maximumDecodedFrames: Int64
    public let maximumDecodedBytes: Int64

    public init(maximumDecodedFrames: Int64, maximumDecodedBytes: Int64) {
        self.maximumDecodedFrames = max(1, maximumDecodedFrames)
        self.maximumDecodedBytes = max(4, maximumDecodedBytes)
    }
}

public struct AudioFileImporter: AudioDecodingService, Sendable {
    public let limits: AudioImportLimits

    public init(limits: AudioImportLimits = .default) { self.limits = limits }

    public func importFile(
        at url: URL,
        progress: AudioImportProgressHandler? = nil
    ) async throws -> ImportedAudioFile {
        try await decodeAudioFile(at: url, progress: progress)
    }

    public func decodeAudioFile(
        at url: URL,
        progress: AudioImportProgressHandler? = nil
    ) async throws -> ImportedAudioFile {
        if Task.isCancelled { throw AudioImportError.cancelled }
        let worker = Task.detached(priority: .userInitiated) {
            try Self.decodeSynchronously(at: url, limits: limits, progress: progress)
        }
        return try await withTaskCancellationHandler {
            do {
                return try await worker.value
            } catch is CancellationError {
                throw AudioImportError.cancelled
            } catch let error as AudioImportError {
                throw error
            } catch {
                throw AudioImportError.decodingFailed(
                    Self.safeContext(error, operation: "Audio decoding", fileName: url.lastPathComponent)
                )
            }
        } onCancel: {
            worker.cancel()
        }
    }

    private static func decodeSynchronously(
        at url: URL,
        limits: AudioImportLimits,
        progress: AudioImportProgressHandler?
    ) throws -> ImportedAudioFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioImportError.fileNotFound(url)
        }
        try checkCancellation()
        progress?(AudioImportProgress(phase: .opening, completedFrames: 0, totalFrames: nil))

        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope { url.stopAccessingSecurityScopedResource() }
        }

        let fileExtension = url.pathExtension.lowercased()
        switch fileExtension {
        case "wav", "wave":
            return try NativeWAVDecoder.decode(url: url, limits: limits, progress: progress)
        case "aif", "aiff", "caf", "m4a":
            return try AVFoundationFileDecoder.decode(url: url, limits: limits, progress: progress)
        default:
            throw AudioImportError.unsupportedContainer(extension: fileExtension)
        }
    }

    fileprivate static func checkCancellation() throws {
        if Task.isCancelled { throw AudioImportError.cancelled }
    }

    /// Framework errors can include the absolute URL in their localized text.
    /// Keep diagnostics useful without allowing a path to escape into logs or
    /// exported error payloads.
    fileprivate static func safeContext(
        _ error: Error,
        operation: String,
        fileName: String
    ) -> ErrorContext {
        var metadata = ["fileName": fileName]
        if let nsError = error as NSError? {
            metadata["errorDomain"] = nsError.domain
            metadata["errorCode"] = String(nsError.code)
        }
        return ErrorContext(
            underlyingType: String(reflecting: type(of: error)),
            diagnosticMessage: "(operation) failed.",
            metadata: metadata
        )
    }
}

private enum NativeWAVDecoder {
    private static let framesPerChunk = 8_192

    private struct Header {
        let formatCode: UInt16
        let sampleRate: SampleRate
        let channelCount: Int
        let bitDepth: Int
        let blockAlignment: Int
        let dataOffset: UInt64
        let dataByteCount: Int
        let fileByteCount: UInt64

        var frameCount: Int { dataByteCount / blockAlignment }
    }

    static func decode(
        url: URL,
        limits: AudioImportLimits,
        progress: AudioImportProgressHandler?
    ) throws -> ImportedAudioFile {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AudioImportError.accessDenied(path: url.path)
        }
        defer { try? handle.close() }

        let header = try readHeader(from: handle, url: url, progress: progress)
        try AudioFileImporter.checkCancellation()
        guard header.dataByteCount > 0, header.frameCount > 0 else {
            throw AudioImportError.emptyFile(url)
        }
        guard Int64(header.frameCount) <= limits.maximumDecodedFrames else {
            throw AudioImportError.inputTooLarge(maximumFrames: limits.maximumDecodedFrames)
        }

        let (sampleCount, sampleOverflow) = header.frameCount.multipliedReportingOverflow(
            by: header.channelCount
        )
        guard !sampleOverflow else {
            throw AudioImportError.corruptedFile(reason: "Decoded sample count overflows addressable memory.")
        }
        let (decodedBytes, byteOverflow) = Int64(sampleCount).multipliedReportingOverflow(by: Int64(MemoryLayout<Float>.size))
        guard !byteOverflow, decodedBytes <= limits.maximumDecodedBytes else {
            throw AudioImportError.inputTooLarge(maximumFrames: limits.maximumDecodedFrames)
        }
        var planar = [Float](repeating: 0, count: sampleCount)
        do {
            try handle.seek(toOffset: header.dataOffset)
        } catch {
            throw AudioImportError.readInterrupted(
                AudioFileImporter.safeContext(error, operation: "Seeking audio data", fileName: url.lastPathComponent)
            )
        }

        progress?(
            AudioImportProgress(
                phase: .decoding,
                completedFrames: 0,
                totalFrames: Int64(header.frameCount)
            )
        )
        var decodedFrames = 0
        while decodedFrames < header.frameCount {
            try AudioFileImporter.checkCancellation()
            let chunkFrames = min(framesPerChunk, header.frameCount - decodedFrames)
            let chunkByteCount = chunkFrames * header.blockAlignment
            let chunk = try readExactly(
                from: handle,
                byteCount: chunkByteCount,
                truncatedReason: "WAV sample data ended before the declared data chunk size.",
                fileName: url.lastPathComponent
            )
            try decodeChunk(
                chunk,
                into: &planar,
                destinationFrame: decodedFrames,
                totalFrames: header.frameCount,
                channelCount: header.channelCount,
                bitDepth: header.bitDepth,
                formatCode: header.formatCode
            )
            decodedFrames += chunkFrames
            progress?(
                AudioImportProgress(
                    phase: .decoding,
                    completedFrames: Int64(decodedFrames),
                    totalFrames: Int64(header.frameCount)
                )
            )
        }

        let audio: AudioSampleBuffer
        do {
            audio = try AudioSampleBuffer(
                samples: planar,
                format: AudioFormatDescriptor(
                    sampleRate: header.sampleRate,
                    channelCount: header.channelCount,
                    bitDepth: 32,
                    isInterleaved: false
                )
            )
        } catch {
            throw AudioImportError.corruptedFile(reason: "Decoded audio could not be represented safely.")
        }
        try AudioFileImporter.checkCancellation()
        progress?(
            AudioImportProgress(
                phase: .analyzing,
                completedFrames: Int64(header.frameCount),
                totalFrames: Int64(header.frameCount)
            )
        )
        let analysis = AudioMetricsAnalyzer().analyze(audio)
        let originalFormat = AudioFileFormatDescription(
            container: .wav,
            encoding: header.formatCode == 3 ? .ieeeFloat : .signedIntegerPCM,
            sampleRate: header.sampleRate,
            channelCount: header.channelCount,
            bitDepth: header.bitDepth,
            isInterleaved: true,
            isBigEndian: false,
            formatIdentifier: header.formatCode == 3 ? "WAVE_FORMAT_IEEE_FLOAT" : "WAVE_FORMAT_PCM"
        )
        progress?(
            AudioImportProgress(
                phase: .completed,
                completedFrames: Int64(header.frameCount),
                totalFrames: Int64(header.frameCount)
            )
        )
        return ImportedAudioFile(
            fileURL: url,
            fileName: url.lastPathComponent,
            originalFormat: originalFormat,
            audio: audio,
            analysis: analysis,
            metadata: [
                "decoder": "AudioLink Native WAV",
                "fileByteCount": String(header.fileByteCount)
            ]
        )
    }

    private static func readHeader(
        from handle: FileHandle,
        url: URL,
        progress: AudioImportProgressHandler?
    ) throws -> Header {
        progress?(AudioImportProgress(phase: .readingHeader, completedFrames: 0, totalFrames: nil))
        let fileByteCount: UInt64
        do {
            fileByteCount = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            throw AudioImportError.readInterrupted(
                AudioFileImporter.safeContext(error, operation: "Seeking WAV header", fileName: url.lastPathComponent)
            )
        }
        guard fileByteCount > 0 else { throw AudioImportError.emptyFile(url) }
        guard fileByteCount >= 12 else {
            throw AudioImportError.corruptedFile(reason: "A WAV file must contain a 12-byte RIFF header.")
        }

            let riff = try readExactly(
                from: handle,
                byteCount: 12,
                truncatedReason: "Incomplete RIFF header.",
                fileName: url.lastPathComponent
        )
        guard riff.ascii(at: 0, count: 4) == "RIFF",
              riff.ascii(at: 8, count: 4) == "WAVE" else {
            throw AudioImportError.corruptedFile(reason: "Expected a little-endian RIFF/WAVE header.")
        }
        let declaredRIFFBytes = UInt64(riff.uint32LE(at: 4)) + 8
        guard declaredRIFFBytes <= fileByteCount else {
            throw AudioImportError.corruptedFile(reason: "RIFF size exceeds the physical file length.")
        }

        var parsedFormat: (UInt16, SampleRate, Int, Int, Int)?
        var dataLocation: (UInt64, Int)?
        var cursor: UInt64 = 12
        while cursor + 8 <= declaredRIFFBytes {
            try AudioFileImporter.checkCancellation()
            try handle.seek(toOffset: cursor)
            let chunkHeader = try readExactly(
                from: handle,
                byteCount: 8,
                truncatedReason: "Incomplete WAV chunk header.",
                fileName: url.lastPathComponent
            )
            let identifier = chunkHeader.ascii(at: 0, count: 4)
            let chunkByteCount = UInt64(chunkHeader.uint32LE(at: 4))
            let chunkDataOffset = cursor + 8
            guard chunkDataOffset + chunkByteCount <= declaredRIFFBytes else {
                throw AudioImportError.corruptedFile(reason: "WAV chunk \(identifier) exceeds the file length.")
            }

            if identifier == "fmt " {
                guard chunkByteCount >= 16, chunkByteCount <= 4_096 else {
                    throw AudioImportError.corruptedFile(reason: "Invalid WAV format chunk size.")
                }
                let formatData = try readExactly(
                    from: handle,
                    byteCount: Int(chunkByteCount),
                    truncatedReason: "Incomplete WAV format chunk.",
                    fileName: url.lastPathComponent
                )
                parsedFormat = try parseFormatChunk(formatData)
            } else if identifier == "data" {
                guard chunkByteCount <= UInt64(Int.max) else {
                    throw AudioImportError.corruptedFile(reason: "WAV data chunk is too large for this process.")
                }
                dataLocation = (chunkDataOffset, Int(chunkByteCount))
            }

            let paddedChunkByteCount = chunkByteCount + (chunkByteCount.isMultiple(of: 2) ? 0 : 1)
            cursor = chunkDataOffset + paddedChunkByteCount
            if parsedFormat != nil, dataLocation != nil { break }
        }

        guard let parsedFormat else {
            throw AudioImportError.corruptedFile(reason: "WAV file does not contain a valid fmt chunk.")
        }
        guard let dataLocation else {
            throw AudioImportError.corruptedFile(reason: "WAV file does not contain a data chunk.")
        }
        let (formatCode, sampleRate, channelCount, bitDepth, blockAlignment) = parsedFormat
        guard dataLocation.1.isMultiple(of: blockAlignment) else {
            throw AudioImportError.corruptedFile(reason: "WAV data size is not aligned to complete sample frames.")
        }
        return Header(
            formatCode: formatCode,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitDepth: bitDepth,
            blockAlignment: blockAlignment,
            dataOffset: dataLocation.0,
            dataByteCount: dataLocation.1,
            fileByteCount: fileByteCount
        )
    }

    private static func parseFormatChunk(
        _ data: Data
    ) throws -> (UInt16, SampleRate, Int, Int, Int) {
        var formatCode = data.uint16LE(at: 0)
        let channelCount = Int(data.uint16LE(at: 2))
        let sampleRateValue = data.uint32LE(at: 4)
        let blockAlignment = Int(data.uint16LE(at: 12))
        let bitDepth = Int(data.uint16LE(at: 14))

        if formatCode == 0xFFFE {
            guard data.count >= 40 else {
                throw AudioImportError.corruptedFile(reason: "Incomplete WAVE_FORMAT_EXTENSIBLE chunk.")
            }
            formatCode = data.uint16LE(at: 24)
        }
        guard channelCount == 1 || channelCount == 2 else {
            throw AudioImportError.unsupportedChannelCount(channelCount)
        }
        let bytesPerSample = bitDepth / 8
        guard bitDepth.isMultiple(of: 8),
              bytesPerSample > 0,
              blockAlignment == channelCount * bytesPerSample else {
            throw AudioImportError.corruptedFile(reason: "WAV block alignment does not match its format.")
        }
        let supported = (formatCode == 1 && [16, 24, 32].contains(bitDepth)) ||
            (formatCode == 3 && bitDepth == 32)
        guard supported else {
            throw AudioImportError.unsupportedWAVEncoding(formatCode: formatCode, bitDepth: bitDepth)
        }
        let sampleRate: SampleRate
        do {
            sampleRate = try SampleRate(hertz: Double(sampleRateValue))
        } catch {
            throw AudioImportError.corruptedFile(reason: "WAV sample rate is invalid.")
        }
        return (formatCode, sampleRate, channelCount, bitDepth, blockAlignment)
    }

    private static func decodeChunk(
        _ data: Data,
        into destination: inout [Float],
        destinationFrame: Int,
        totalFrames: Int,
        channelCount: Int,
        bitDepth: Int,
        formatCode: UInt16
    ) throws {
        let bytesPerSample = bitDepth / 8
        let frameCount = data.count / (bytesPerSample * channelCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let sampleOffset = (frame * channelCount + channel) * bytesPerSample
                let sample: Float
                switch (formatCode, bitDepth) {
                case (1, 16):
                    let value = Int16(bitPattern: data.uint16LE(at: sampleOffset))
                    sample = value < 0
                        ? Float(value) / 32_768
                        : Float(value) / 32_767
                case (1, 24):
                    var value = Int32(data[sampleOffset]) |
                        (Int32(data[sampleOffset + 1]) << 8) |
                        (Int32(data[sampleOffset + 2]) << 16)
                    if value & 0x0080_0000 != 0 { value |= Int32(bitPattern: 0xFF00_0000) }
                    sample = value < 0
                        ? Float(value) / 8_388_608
                        : Float(value) / 8_388_607
                case (1, 32):
                    let value = Int32(bitPattern: data.uint32LE(at: sampleOffset))
                    sample = value < 0
                        ? Float(Double(value) / 2_147_483_648)
                        : Float(Double(value) / 2_147_483_647)
                case (3, 32):
                    sample = Float(bitPattern: data.uint32LE(at: sampleOffset))
                default:
                    throw AudioImportError.unsupportedWAVEncoding(
                        formatCode: formatCode,
                        bitDepth: bitDepth
                    )
                }
                guard sample.isFinite else {
                    throw AudioImportError.corruptedFile(reason: "WAV contains NaN or infinity.")
                }
                destination[channel * totalFrames + destinationFrame + frame] = sample
            }
        }
    }

    private static func readExactly(
        from handle: FileHandle,
        byteCount: Int,
        truncatedReason: String,
        fileName: String
    ) throws -> Data {
        do {
            let data = try handle.read(upToCount: byteCount) ?? Data()
            guard data.count == byteCount else {
                throw AudioImportError.corruptedFile(reason: truncatedReason)
            }
            return data
        } catch let error as AudioImportError {
            throw error
        } catch {
            throw AudioImportError.readInterrupted(
                AudioFileImporter.safeContext(error, operation: "Reading WAV data", fileName: fileName)
            )
        }
    }
}

private enum AVFoundationFileDecoder {
    private static let framesPerChunk: AVAudioFrameCount = 8_192

    static func decode(
        url: URL,
        limits: AudioImportLimits,
        progress: AudioImportProgressHandler?
    ) throws -> ImportedAudioFile {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioImportError.decodingFailed(
                AudioFileImporter.safeContext(error, operation: "Opening audio", fileName: url.lastPathComponent)
            )
        }
        let processingFormat = file.processingFormat
        let channelCount = Int(processingFormat.channelCount)
        guard channelCount == 1 || channelCount == 2 else {
            throw AudioImportError.unsupportedChannelCount(channelCount)
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: framesPerChunk
        ) else {
            throw AudioImportError.decodingFailed(
                ErrorContext(diagnosticMessage: "AVFoundation could not allocate a decode buffer.")
            )
        }

        let estimatedFrames = max(0, file.length)
        guard estimatedFrames <= limits.maximumDecodedFrames else {
            throw AudioImportError.inputTooLarge(maximumFrames: limits.maximumDecodedFrames)
        }
        var channels = [[Float]](repeating: [], count: channelCount)
        if estimatedFrames <= AVAudioFramePosition(Int.max) {
            for channel in 0..<channelCount {
                channels[channel].reserveCapacity(Int(estimatedFrames))
            }
        }
        var decodedFrames: Int64 = 0
        progress?(
            AudioImportProgress(
                phase: .decoding,
                completedFrames: 0,
                totalFrames: estimatedFrames > 0 ? estimatedFrames : nil
            )
        )
        while estimatedFrames <= 0 || decodedFrames < estimatedFrames {
            try AudioFileImporter.checkCancellation()
            buffer.frameLength = 0
            let requestedFrames: AVAudioFrameCount
            if estimatedFrames > 0 {
                let remaining = estimatedFrames - decodedFrames
                requestedFrames = AVAudioFrameCount(min(Int64(framesPerChunk), remaining))
            } else {
                requestedFrames = framesPerChunk
            }
            do {
                try file.read(into: buffer, frameCount: requestedFrames)
            } catch {
                throw AudioImportError.readInterrupted(
                    AudioFileImporter.safeContext(error, operation: "Reading audio", fileName: url.lastPathComponent)
                )
            }
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0 else { break }
            guard decodedFrames <= limits.maximumDecodedFrames - Int64(framesRead) else {
                throw AudioImportError.inputTooLarge(maximumFrames: limits.maximumDecodedFrames)
            }
            guard let channelData = buffer.floatChannelData else {
                throw AudioImportError.decodingFailed(
                    ErrorContext(diagnosticMessage: "AVFoundation returned non-Float PCM data.")
                )
            }
            for channel in 0..<channelCount {
                channels[channel].append(
                    contentsOf: UnsafeBufferPointer(start: channelData[channel], count: framesRead)
                )
            }
            decodedFrames += Int64(framesRead)
            progress?(
                AudioImportProgress(
                    phase: .decoding,
                    completedFrames: decodedFrames,
                    totalFrames: estimatedFrames > 0 ? estimatedFrames : nil
                )
            )
        }
        guard decodedFrames > 0 else { throw AudioImportError.emptyFile(url) }

        var planar: [Float] = []
        let (sampleCount, overflow) = Int(decodedFrames).multipliedReportingOverflow(by: channelCount)
        guard !overflow else {
            throw AudioImportError.decodingFailed(
                ErrorContext(diagnosticMessage: "Decoded sample count overflows addressable memory.")
            )
        }
        let (decodedBytes, byteOverflow) = Int64(sampleCount).multipliedReportingOverflow(by: Int64(MemoryLayout<Float>.size))
        guard !byteOverflow, decodedBytes <= limits.maximumDecodedBytes else {
            throw AudioImportError.inputTooLarge(maximumFrames: limits.maximumDecodedFrames)
        }
        planar.reserveCapacity(sampleCount)
        for channel in channels { planar.append(contentsOf: channel) }
        let sampleRate: SampleRate
        do {
            sampleRate = try SampleRate(hertz: processingFormat.sampleRate)
        } catch {
            throw AudioImportError.decodingFailed(
                AudioFileImporter.safeContext(error, operation: "Building imported audio", fileName: url.lastPathComponent)
            )
        }
        let audio: AudioSampleBuffer
        do {
            audio = try AudioSampleBuffer(
                samples: planar,
                format: AudioFormatDescriptor(
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    bitDepth: 32,
                    isInterleaved: false
                )
            )
        } catch {
            throw AudioImportError.decodingFailed(
                AudioFileImporter.safeContext(error, operation: "Analyzing imported audio", fileName: url.lastPathComponent)
            )
        }
        let diskDescription = file.fileFormat.streamDescription.pointee
        let originalSampleRate = try? SampleRate(hertz: diskDescription.mSampleRate)
        let container = container(for: url.pathExtension.lowercased())
        let isLinearPCM = diskDescription.mFormatID == kAudioFormatLinearPCM
        let isFloat = diskDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let encoding: AudioFileSampleEncoding = isLinearPCM
            ? (isFloat ? .ieeeFloat : .signedIntegerPCM)
            : .compressed
        let originalFormat = AudioFileFormatDescription(
            container: container,
            encoding: encoding,
            sampleRate: originalSampleRate ?? sampleRate,
            channelCount: Int(diskDescription.mChannelsPerFrame),
            bitDepth: Int(diskDescription.mBitsPerChannel),
            isInterleaved: diskDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
            isBigEndian: diskDescription.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
            formatIdentifier: fourCharacterCode(diskDescription.mFormatID)
        )
        progress?(
            AudioImportProgress(
                phase: .analyzing,
                completedFrames: decodedFrames,
                totalFrames: decodedFrames
            )
        )
        let analysis = AudioMetricsAnalyzer().analyze(audio)
        progress?(
            AudioImportProgress(
                phase: .completed,
                completedFrames: decodedFrames,
                totalFrames: decodedFrames
            )
        )
        return ImportedAudioFile(
            fileURL: url,
            fileName: url.lastPathComponent,
            originalFormat: originalFormat,
            audio: audio,
            analysis: analysis,
            metadata: ["decoder": "AVFoundation"]
        )
    }

    private static func container(for fileExtension: String) -> AudioFileContainer {
        switch fileExtension {
        case "aif", "aiff": .aiff
        case "caf": .caf
        case "m4a": .m4a
        default: .unknown
        }
    }

    private static func fourCharacterCode(_ value: AudioFormatID) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        let printable = bytes.map { byte in
            Character(UnicodeScalar(byte >= 32 && byte <= 126 ? byte : 46))
        }
        return String(printable)
    }
}

private extension Data {
    func ascii(at offset: Int, count: Int) -> String {
        String(decoding: self[offset..<(offset + count)], as: UTF8.self)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
