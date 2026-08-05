import AudioLinkCore
import AudioLinkDSP
import Foundation

private enum CommandLineError: Error, LocalizedError {
    case missingInput
    case missingValue(String)
    case invalidNumber(option: String, value: String)
    case invalidEncoding(String)
    case unknownOption(String)
    case outputMatchesInput

    var errorDescription: String? {
        switch self {
        case .missingInput:
            "An input audio file path is required."
        case let .missingValue(option):
            "Missing value for \(option)."
        case let .invalidNumber(option, value):
            "Invalid numeric value '\(value)' for \(option)."
        case let .invalidEncoding(value):
            "Unknown WAV encoding '\(value)'."
        case let .unknownOption(option):
            "Unknown option \(option)."
        case .outputMatchesInput:
            "The output WAV path must not overwrite the input file."
        }
    }
}

private struct Options {
    let inputPath: String
    var outputPath: String?
    var jsonOutputPath: String?
    var encoding = WAVEncoding.pcmInt16
    var selectedChannel: Int?
    var downmixToMono = false
    var removeDCOffset = false
    var leadingSilenceThreshold: Float?
    var trailingSilenceThreshold: Float?
    var highPassCutoff: Double?
    var targetSampleRate: Double?
    var invertPolarity = false
    var gain: Float?
    var peakNormalization: Float?
    var rmsNormalization: Float?

    static func parse(_ arguments: [String]) throws -> Self? {
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return nil
        }
        guard let inputPath = arguments.first, !inputPath.hasPrefix("--") else {
            throw CommandLineError.missingInput
        }
        var result = Self(inputPath: inputPath)
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--downmix-mono":
                result.downmixToMono = true
                index += 1
            case "--remove-dc":
                result.removeDCOffset = true
                index += 1
            case "--invert-polarity":
                result.invertPolarity = true
                index += 1
            default:
                guard index + 1 < arguments.count else {
                    throw CommandLineError.missingValue(option)
                }
                let value = arguments[index + 1]
                switch option {
                case "--output":
                    result.outputPath = value
                case "--json-output":
                    result.jsonOutputPath = value
                case "--encoding":
                    guard let encoding = WAVEncoding(rawValue: value) else {
                        throw CommandLineError.invalidEncoding(value)
                    }
                    result.encoding = encoding
                case "--channel":
                    result.selectedChannel = try parseInt(value, option: option)
                case "--trim-leading":
                    result.leadingSilenceThreshold = try parseFloat(value, option: option)
                case "--trim-trailing":
                    result.trailingSilenceThreshold = try parseFloat(value, option: option)
                case "--high-pass":
                    result.highPassCutoff = try parseDouble(value, option: option)
                case "--sample-rate":
                    result.targetSampleRate = try parseDouble(value, option: option)
                case "--gain":
                    result.gain = try parseFloat(value, option: option)
                case "--peak-normalize":
                    result.peakNormalization = try parseFloat(value, option: option)
                case "--rms-normalize":
                    result.rmsNormalization = try parseFloat(value, option: option)
                default:
                    throw CommandLineError.unknownOption(option)
                }
                index += 2
            }
        }
        return result
    }

    func preprocessingConfiguration() throws -> PreprocessingConfiguration {
        PreprocessingConfiguration(
            selectedChannel: selectedChannel,
            downmixToMono: downmixToMono,
            removeDCOffset: removeDCOffset,
            trimLeadingSilence: leadingSilenceThreshold.map {
                SilenceTrimmingConfiguration(threshold: $0)
            },
            trimTrailingSilence: trailingSilenceThreshold.map {
                SilenceTrimmingConfiguration(threshold: $0)
            },
            highPassFilter: highPassCutoff.map {
                HighPassFilterConfiguration(cutoffFrequencyHertz: $0)
            },
            targetSampleRate: try targetSampleRate.map { try SampleRate(hertz: $0) },
            invertPolarity: invertPolarity,
            gain: gain,
            peakNormalizationTarget: peakNormalization,
            rmsNormalizationTarget: rmsNormalization
        )
    }

    static func printUsage() {
        print("""
        Inspect and preprocess an audio file using AudioLinkDSP.

        Usage: AudioLinkAudioFileTool INPUT [options]
          --output PATH              Export processed WAV
          --json-output PATH         Write JSON report; otherwise print to stdout
          --encoding VALUE           pcmInt16, pcmInt24, pcmInt32, ieeeFloat32
          --channel INDEX            Select one zero-based channel
          --downmix-mono             Downmix stereo to mono
          --remove-dc                Remove per-channel DC offset
          --trim-leading THRESHOLD   Trim leading samples at or below threshold
          --trim-trailing THRESHOLD  Trim trailing samples at or below threshold
          --high-pass HZ             Apply a second-order Butterworth high-pass
          --sample-rate HZ           Resample with AVAudioConverter
          --invert-polarity          Multiply samples by -1
          --gain VALUE               Apply safe non-negative linear gain
          --peak-normalize VALUE     Normalize peak to 0...1
          --rms-normalize VALUE      Normalize RMS to 0...1 if it will not clip
        """)
    }

    private static func parseDouble(_ value: String, option: String) throws -> Double {
        guard let result = Double(value) else {
            throw CommandLineError.invalidNumber(option: option, value: value)
        }
        return result
    }

    private static func parseFloat(_ value: String, option: String) throws -> Float {
        guard let result = Float(value) else {
            throw CommandLineError.invalidNumber(option: option, value: value)
        }
        return result
    }

    private static func parseInt(_ value: String, option: String) throws -> Int {
        guard let result = Int(value) else {
            throw CommandLineError.invalidNumber(option: option, value: value)
        }
        return result
    }
}

private struct AudioFileReport: Codable {
    let fileURL: String
    let fileName: String
    let originalFormat: AudioFileFormatDescription
    let internalFormat: AudioFormatDescriptor
    let frameCount: Int
    let durationSeconds: Double
    let analysis: AudioAnalysisMetrics
    let metadata: [String: String]
    let preprocessingLog: [PreprocessingLogEntry]
    let preprocessingSummary: [String]
    let wasResampled: Bool

    init(file: ImportedAudioFile) {
        fileURL = file.fileURL.path
        fileName = file.fileName
        originalFormat = file.originalFormat
        internalFormat = file.internalFormat
        frameCount = file.frameCount
        durationSeconds = file.duration.value
        analysis = file.analysis
        metadata = file.metadata
        preprocessingLog = file.preprocessingLog
        preprocessingSummary = file.preprocessingSummary
        wasResampled = file.wasResampled
    }
}

@main
private enum AudioLinkAudioFileTool {
    static func main() async throws {
        guard let options = try Options.parse(Array(CommandLine.arguments.dropFirst())) else { return }
        let inputURL = URL(fileURLWithPath: options.inputPath).standardizedFileURL
        let imported = try await AudioFileImporter().importFile(at: inputURL)
        let processed = try await AudioPreprocessor().process(
            imported,
            configuration: try options.preprocessingConfiguration()
        )

        if let outputPath = options.outputPath {
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            guard outputURL != inputURL else { throw CommandLineError.outputMatchesInput }
            try WAVExporter().write(processed.audio, to: outputURL, encoding: options.encoding)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportData = try encoder.encode(AudioFileReport(file: processed))
        if let jsonOutputPath = options.jsonOutputPath {
            try reportData.write(
                to: URL(fileURLWithPath: jsonOutputPath).standardizedFileURL,
                options: .atomic
            )
        } else {
            print(String(decoding: reportData, as: UTF8.self))
        }
    }
}
