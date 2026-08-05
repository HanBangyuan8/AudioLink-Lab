import AudioLinkCore
import AudioLinkDSP
import Foundation

private enum CommandLineError: Error, LocalizedError {
    case missingValue(String)
    case invalidNumber(option: String, value: String)
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case let .missingValue(option):
            "Missing value for \(option)."
        case let .invalidNumber(option, value):
            "Invalid numeric value '\(value)' for \(option)."
        case let .unknownOption(option):
            "Unknown option \(option)."
        }
    }
}

private struct Options {
    var outputPath = "AudioLink-48k-2s-log-sweep.wav"
    var sampleRate = 48_000.0
    var duration = 2.0
    var startFrequency = 20.0
    var endFrequency = 20_000.0
    var amplitude: Float = 0.8

    static func parse(_ arguments: [String]) throws -> Self? {
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return nil
        }

        var result = Self()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw CommandLineError.missingValue(option)
            }
            let value = arguments[index + 1]
            switch option {
            case "--output":
                result.outputPath = value
            case "--sample-rate":
                guard let parsed = Double(value) else {
                    throw CommandLineError.invalidNumber(option: option, value: value)
                }
                result.sampleRate = parsed
            case "--duration":
                guard let parsed = Double(value) else {
                    throw CommandLineError.invalidNumber(option: option, value: value)
                }
                result.duration = parsed
            case "--start-frequency":
                guard let parsed = Double(value) else {
                    throw CommandLineError.invalidNumber(option: option, value: value)
                }
                result.startFrequency = parsed
            case "--end-frequency":
                guard let parsed = Double(value) else {
                    throw CommandLineError.invalidNumber(option: option, value: value)
                }
                result.endFrequency = parsed
            case "--amplitude":
                guard let parsed = Float(value) else {
                    throw CommandLineError.invalidNumber(option: option, value: value)
                }
                result.amplitude = parsed
            default:
                throw CommandLineError.unknownOption(option)
            }
            index += 2
        }
        return result
    }

    static func printUsage() {
        print("""
        Generate a logarithmic sweep WAV for AudioLink development.

        Usage: AudioLinkSignalTool [options]
          --output PATH             Output WAV path
          --sample-rate HZ          Default: 48000
          --duration SECONDS        Default: 2
          --start-frequency HZ      Default: 20
          --end-frequency HZ        Default: 20000
          --amplitude VALUE         Normalized 0...1, default: 0.8
        """)
    }
}

@main
private enum AudioLinkSignalTool {
    static func main() throws {
        guard let options = try Options.parse(Array(CommandLine.arguments.dropFirst())) else { return }
        let sampleRate = try SampleRate(hertz: options.sampleRate)
        let configuration = TestSignalConfiguration(
            kind: .logarithmicSweep,
            sampleRate: sampleRate,
            duration: try DurationSeconds(options.duration),
            startFrequencyHertz: options.startFrequency,
            endFrequencyHertz: options.endFrequency,
            amplitude: options.amplitude,
            fadeIn: try DurationSeconds(min(0.01, options.duration / 4)),
            fadeOut: try DurationSeconds(min(0.01, options.duration / 4))
        )
        let generated = try TestSignalGenerator().generate(configuration: configuration)
        let outputURL = URL(fileURLWithPath: options.outputPath).standardizedFileURL
        try WAVExporter().write(generated.audio, to: outputURL)
        print("Wrote \(generated.audio.frameCount) frames at \(Int(sampleRate.hertz)) Hz to \(outputURL.path)")
    }
}
