import AudioLinkCore
import AudioLinkDSP
import Foundation
import Darwin

private enum ToolError: Error, LocalizedError {
    case missingInputs
    case missingValue(String)
    case invalidInteger(option: String, value: String)
    case invalidMethod(String)
    case invalidPolarity(String)
    case invalidSequenceOutput(String)
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case .missingInputs:
            "Reference and observed audio paths are required."
        case let .missingValue(option):
            "Missing value for \(option)."
        case let .invalidInteger(option, value):
            "Invalid integer '\(value)' for \(option)."
        case let .invalidMethod(value):
            "Unknown correlation method '\(value)'."
        case let .invalidPolarity(value):
            "Unknown peak polarity '\(value)'."
        case let .invalidSequenceOutput(value):
            "Unknown sequence output mode '\(value)'."
        case let .unknownOption(option):
            "Unknown option \(option)."
        }
    }
}

private struct Options {
    let referencePath: String
    let observedPath: String
    var jsonOutputPath: String?
    var method = CorrelationMethod.automatic
    var minimumLag: Int64?
    var maximumLag: Int64?
    var polarity = CorrelationPeakSelection.absolute
    var sequenceOutput = CorrelationSequenceOutput.none
    var channel = 0

    static func parse(_ arguments: [String]) throws -> Self? {
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return nil
        }
        guard arguments.count >= 2,
              !arguments[0].hasPrefix("--"),
              !arguments[1].hasPrefix("--") else {
            throw ToolError.missingInputs
        }
        var options = Self(referencePath: arguments[0], observedPath: arguments[1])
        var index = 2
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw ToolError.missingValue(option) }
            let value = arguments[index + 1]
            switch option {
            case "--json-output":
                options.jsonOutputPath = value
            case "--method":
                guard let method = CorrelationMethod(rawValue: value) else {
                    throw ToolError.invalidMethod(value)
                }
                options.method = method
            case "--min-lag":
                options.minimumLag = try parseInt64(value, option: option)
            case "--max-lag":
                options.maximumLag = try parseInt64(value, option: option)
            case "--polarity":
                guard let polarity = CorrelationPeakSelection(rawValue: value) else {
                    throw ToolError.invalidPolarity(value)
                }
                options.polarity = polarity
            case "--sequence":
                guard let output = CorrelationSequenceOutput(rawValue: value) else {
                    throw ToolError.invalidSequenceOutput(value)
                }
                options.sequenceOutput = output
            case "--channel":
                guard let channel = Int(value) else {
                    throw ToolError.invalidInteger(option: option, value: value)
                }
                options.channel = channel
            default:
                throw ToolError.unknownOption(option)
            }
            index += 2
        }
        return options
    }

    var searchRange: SampleLagRange? {
        guard minimumLag != nil || maximumLag != nil else { return nil }
        return SampleLagRange(
            minimum: minimumLag ?? Int64.min,
            maximum: maximumLag ?? Int64.max
        )
    }

    static func printUsage() {
        print("""
        Estimate delay between two audio files using AudioLinkDSP.

        Usage: AudioLinkCorrelationTool REFERENCE OBSERVED [options]
          --json-output PATH       Write JSON report; otherwise print to stdout
          --method VALUE           automatic, direct, fft
          --min-lag SAMPLES        Inclusive minimum lag
          --max-lag SAMPLES        Inclusive maximum lag
          --polarity VALUE         absolute, positive, negative
          --sequence VALUE         none, searchedRange, full
          --channel INDEX          Explicit zero-based channel to analyze
        """)
    }

    private static func parseInt64(_ value: String, option: String) throws -> Int64 {
        guard let result = Int64(value) else {
            throw ToolError.invalidInteger(option: option, value: value)
        }
        return result
    }
}

private struct CorrelationToolReport: Codable {
    let referencePath: String
    let observedPath: String
    let referenceFormat: AudioFormatDescriptor
    let observedFormat: AudioFormatDescriptor
    let configuration: CorrelationConfiguration
    let result: DelayAnalysisResult
}

@main
private enum AudioLinkCorrelationTool {
    static func main() async {
        do {
            try await run()
        } catch {
            // Keep command-line failures actionable and non-crashing. A thrown
            // error from an async @main entry point is rendered as a fatal
            // runtime error by Swift, which is especially unhelpful for
            // malformed or incompatible input files.
            let message = error.localizedDescription
            fputs("AudioLinkCorrelationTool: \(message)\n", stderr)
            exit(2)
        }
    }

    private static func run() async throws {
        guard let options = try Options.parse(Array(CommandLine.arguments.dropFirst())) else { return }
        let referenceURL = URL(fileURLWithPath: options.referencePath).standardizedFileURL
        let observedURL = URL(fileURLWithPath: options.observedPath).standardizedFileURL
        async let referenceImport = AudioFileImporter().importFile(at: referenceURL)
        async let observedImport = AudioFileImporter().importFile(at: observedURL)
        let (reference, observed) = try await (referenceImport, observedImport)
        let configuration = CorrelationConfiguration(
            method: options.method,
            searchRange: options.searchRange,
            peakSelection: options.polarity,
            sequenceOutput: options.sequenceOutput,
            channel: options.channel
        )
        let result = try await DelayAnalysisEngine().analyze(
            reference: reference.audio,
            observed: observed.audio,
            configuration: configuration
        )
        let report = CorrelationToolReport(
            referencePath: referenceURL.path,
            observedPath: observedURL.path,
            referenceFormat: reference.internalFormat,
            observedFormat: observed.internalFormat,
            configuration: configuration,
            result: result
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        if let outputPath = options.jsonOutputPath {
            try data.write(
                to: URL(fileURLWithPath: outputPath).standardizedFileURL,
                options: .atomic
            )
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
