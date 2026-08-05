import AudioLinkCore
import Foundation

public enum WAVEncoding: String, Codable, CaseIterable, Sendable {
    case pcmInt16
    case pcmInt24
    case pcmInt32
    case ieeeFloat32

    fileprivate var formatCode: UInt16 {
        switch self {
        case .pcmInt16, .pcmInt24, .pcmInt32: 1
        case .ieeeFloat32: 3
        }
    }

    fileprivate var bitsPerSample: UInt16 {
        switch self {
        case .pcmInt16: 16
        case .pcmInt24: 24
        case .pcmInt32: 32
        case .ieeeFloat32: 32
        }
    }
}

public enum WAVExportError: Error, Equatable, Sendable {
    case invalidSampleRate(Double)
    case invalidChannelCount(Int)
    case dataTooLarge
    case fileWriteFailed(ErrorContext)
}

extension WAVExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            "WAV export requires a positive whole-number sample rate representable by UInt32."
        case .invalidChannelCount:
            "WAV channel count must be representable by UInt16."
        case .dataTooLarge:
            "WAV data exceeds the classic RIFF 32-bit size limit."
        case .fileWriteFailed:
            "The WAV file could not be written."
        }
    }
}

public struct WAVExporter: Sendable {
    public init() {}

    /// Creates a standard little-endian RIFF/WAVE file. PCM Int16 is the
    /// default because it is accepted by the broadest set of audio tools.
    public func data(
        for buffer: AudioSampleBuffer,
        encoding: WAVEncoding = .pcmInt16
    ) throws -> Data {
        let exactSampleRate = buffer.format.sampleRate.hertz
        let roundedSampleRate = exactSampleRate.rounded()
        guard exactSampleRate.isFinite,
              roundedSampleRate > 0,
              roundedSampleRate <= Double(UInt32.max),
              abs(exactSampleRate - roundedSampleRate) < 0.000_001 else {
            throw WAVExportError.invalidSampleRate(exactSampleRate)
        }
        guard buffer.channelCount > 0, buffer.channelCount <= Int(UInt16.max) else {
            throw WAVExportError.invalidChannelCount(buffer.channelCount)
        }

        let bytesPerSample = Int(encoding.bitsPerSample / 8)
        let (interleavedSampleCount, sampleCountOverflow) = buffer.frameCount
            .multipliedReportingOverflow(by: buffer.channelCount)
        let (dataByteCount, dataSizeOverflow) = interleavedSampleCount
            .multipliedReportingOverflow(by: bytesPerSample)
        let dataPaddingByteCount = dataByteCount.isMultiple(of: 2) ? 0 : 1
        guard !sampleCountOverflow,
              !dataSizeOverflow,
              dataByteCount <= Int(UInt32.max) - 36 - dataPaddingByteCount else {
            throw WAVExportError.dataTooLarge
        }

        let blockAlignmentValue = buffer.channelCount * bytesPerSample
        guard blockAlignmentValue <= Int(UInt16.max) else {
            throw WAVExportError.invalidChannelCount(buffer.channelCount)
        }
        let channelCount = UInt16(buffer.channelCount)
        let sampleRate = UInt32(roundedSampleRate)
        let blockAlignment = UInt16(blockAlignmentValue)
        let (byteRate, byteRateOverflow) = sampleRate.multipliedReportingOverflow(by: UInt32(blockAlignment))
        guard !byteRateOverflow else { throw WAVExportError.dataTooLarge }

        var result = Data()
        result.reserveCapacity(44 + dataByteCount + dataPaddingByteCount)
        result.appendASCII("RIFF")
        result.appendLittleEndian(UInt32(36 + dataByteCount + dataPaddingByteCount))
        result.appendASCII("WAVE")
        result.appendASCII("fmt ")
        result.appendLittleEndian(UInt32(16))
        result.appendLittleEndian(encoding.formatCode)
        result.appendLittleEndian(channelCount)
        result.appendLittleEndian(sampleRate)
        result.appendLittleEndian(byteRate)
        result.appendLittleEndian(blockAlignment)
        result.appendLittleEndian(encoding.bitsPerSample)
        result.appendASCII("data")
        result.appendLittleEndian(UInt32(dataByteCount))

        for frame in 0..<buffer.frameCount {
            for channel in 0..<buffer.channelCount {
                let sample = buffer.samples[channel * buffer.frameCount + frame]
                switch encoding {
                case .pcmInt16:
                    let encoded: Int16
                    if sample <= -1 {
                        encoded = .min
                    } else if sample >= 1 {
                        encoded = .max
                    } else {
                        encoded = Int16((sample * Float(Int16.max)).rounded())
                    }
                    result.appendLittleEndian(encoded)
                case .pcmInt24:
                    let encoded: Int32
                    if sample <= -1 {
                        encoded = -8_388_608
                    } else if sample >= 1 {
                        encoded = 8_388_607
                    } else {
                        encoded = Int32((Double(sample) * 8_388_607).rounded())
                    }
                    result.appendInt24LittleEndian(encoded)
                case .pcmInt32:
                    let encoded: Int32
                    if sample <= -1 {
                        encoded = .min
                    } else if sample >= 1 {
                        encoded = .max
                    } else {
                        encoded = Int32((Double(sample) * Double(Int32.max)).rounded())
                    }
                    result.appendLittleEndian(encoded)
                case .ieeeFloat32:
                    result.appendLittleEndian(sample.bitPattern)
                }
            }
        }
        if dataPaddingByteCount == 1 { result.append(0) }
        return result
    }

    public func write(
        _ buffer: AudioSampleBuffer,
        to url: URL,
        encoding: WAVEncoding = .pcmInt16,
        options: Data.WritingOptions = .atomic
    ) throws {
        do {
            try data(for: buffer, encoding: encoding).write(to: url, options: options)
        } catch let error as WAVExportError {
            throw error
        } catch {
            throw WAVExportError.fileWriteFailed(
                ErrorContext(error: error, metadata: ["fileName": url.lastPathComponent])
            )
        }
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendInt24LittleEndian(_ value: Int32) {
        let bits = UInt32(bitPattern: value)
        append(UInt8(bits & 0xFF))
        append(UInt8((bits >> 8) & 0xFF))
        append(UInt8((bits >> 16) & 0xFF))
    }
}
