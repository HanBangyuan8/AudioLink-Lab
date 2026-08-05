import AudioLinkAutomation
import AudioLinkBundle
import AudioLinkCore
import AudioLinkDSP
import AudioLinkRealtime
import AudioLinkReporting
import AudioLinkStorage
import AudioLinkPlatform
import Foundation

#if os(macOS)
import Darwin
#endif

private enum CLIExitCode: Int32 { case success = 0, usage = 2, input = 3, unsupported = 4, cancelled = 5, execution = 6 }

private struct ParsedCLIArguments {
    let command: String
    var options: [String: String]
    var flags: Set<String>
    let positionals: [String]

    init(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw CLIError.usage("A subcommand is required. Use --help for help.") }
        self.command = command
        var options: [String: String] = [:]; var flags = Set<String>(); var positionals: [String] = []
        var index = 1
        while index < arguments.count {
            let value = arguments[index]
            if value == "--" { positionals.append(contentsOf: arguments.dropFirst(index + 1)); break }
            guard value.hasPrefix("--") else { positionals.append(value); index += 1; continue }
            let parts = value.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0]
            if parts.count == 2 { options[key] = parts[1]; index += 1; continue }
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") { options[key] = arguments[index + 1]; index += 2 }
            else { flags.insert(key); index += 1 }
        }
        self.options = options; self.flags = flags; self.positionals = positionals
    }

    func value(_ key: String) -> String? { options[key] }
    func has(_ key: String) -> Bool { flags.contains(key) || options[key] != nil }
    func require(_ key: String) throws -> String { guard let value = options[key], !value.isEmpty else { throw CLIError.usage("Missing --\(key).") }; return value }
    func double(_ key: String) throws -> Double? { guard let value = options[key] else { return nil }; guard let number = Double(value), number.isFinite else { throw CLIError.usage("Invalid number for --\(key): \(value)") }; return number }
    func int(_ key: String) throws -> Int? { guard let value = options[key] else { return nil }; guard let number = Int(value) else { throw CLIError.usage("Invalid integer for --\(key): \(value)") }; return number }
}

private enum CLIError: Error, LocalizedError {
    case usage(String)
    case input(String)
    case unsupported(String)
    case execution(String)
    var errorDescription: String? {
        switch self { case .usage(let message), .input(let message), .unsupported(let message), .execution(let message): message }
    }
}

private struct CLIOutput: Codable {
    let schemaVersion: String
    let command: String
    let status: String
    let result: JSONValue?
    let error: String?
}

#if os(macOS)
/// Converts terminal interrupts into cooperative task cancellation.  Hardware
/// adapters can observe the same task cancellation and run their normal
/// restoration/defer paths instead of being terminated as an unstructured
/// process kill.
private final class CLIInterruptController: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]

    init(handler: @escaping @Sendable () -> Void) {
        let signalNumbers: [Int32] = [SIGINT, SIGTERM]
        self.sources = signalNumbers.map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }

    deinit { sources.forEach { $0.cancel() } }
}
#endif

@main
private struct AudioLinkCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.contains("--help") || arguments.first == "help" { printHelp(); return }
        do {
            let parsed = try ParsedCLIArguments(arguments)
            let execution = Task { try await run(parsed) }
            #if os(macOS)
            let interruptController = CLIInterruptController { execution.cancel() }
            #endif
            do {
                let exitCode = try await execution.value
                #if os(macOS)
                withExtendedLifetime(interruptController) { exit(exitCode.rawValue) }
                #else
                exit(exitCode.rawValue)
                #endif
            } catch is CancellationError {
                emitError(CLIError.execution("The operation was cancelled."), json: arguments.contains("--json"))
                exit(CLIExitCode.cancelled.rawValue)
            }
        } catch {
            let wantsJSON = arguments.contains("--json")
            emitError(error, json: wantsJSON)
            exit(code(for: error).rawValue)
        }
    }

    private static func run(_ args: ParsedCLIArguments) async throws -> CLIExitCode {
        switch args.command {
        case "generate-signal": try generateSignal(args); return .success
        case "analyze-files": try await analyzeFiles(args); return .success
        case "devices": try await listDevices(args); return .success
        case "device-info": try await deviceInfo(args); return .success
        case "history": try await history(args); return .success
        case "export-report": try await exportReport(args); return .success
        case "run-plan": try await runPlan(args); return .success
        case "validate": try validateInput(args); return .success
        case "estimate-drift": try estimateDrift(args); return .success
        case "measure-loopback", "benchmark-device", "profile-plugin", "analyze-path":
            throw CLIError.unsupported("\(args.command) requires a hardware/plugin/path adapter and is not executed by this headless build. No measurement is claimed.")
        default: throw CLIError.usage("Unknown subcommand `\(args.command)`. Use --help for the command list.")
        }
    }

    private static func generateSignal(_ args: ParsedCLIArguments) throws {
        let output = try args.require("output")
        let sampleRate = try SampleRate(hertz: args.double("sample-rate") ?? 48_000)
        let duration = try DurationSeconds(args.double("duration") ?? 2)
        let kind = SignalKind(rawValue: args.value("signal") ?? SignalKind.logarithmicSweep.rawValue) ?? .logarithmicSweep
        let startFrequency = try args.double("start-frequency") ?? 20
        let endFrequency = try args.double("end-frequency") ?? min(20_000, sampleRate.hertz / 2 - 1)
        let amplitude = Float(try args.double("amplitude") ?? 0.5)
        let configuration = TestSignalConfiguration(kind: kind, sampleRate: sampleRate, duration: duration,
            startFrequencyHertz: startFrequency,
            endFrequencyHertz: endFrequency,
            amplitude: amplitude,
            preRollSilence: try DurationSeconds(args.double("pre-roll") ?? 0),
            postRollSilence: try DurationSeconds(args.double("post-roll") ?? 0),
            fadeIn: try DurationSeconds(args.double("fade-in") ?? 0.01), fadeOut: try DurationSeconds(args.double("fade-out") ?? 0.01),
            deterministicSeed: UInt64(args.value("seed") ?? "") ?? 0xA0D1_01A5_1A8B_1E5D)
        let generated = try TestSignalGenerator().generate(configuration: configuration)
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        try ensureWritable(outputURL, overwrite: args.has("overwrite"))
        try WAVExporter().write(generated.audio, to: outputURL,
                                encoding: WAVEncoding(rawValue: args.value("format") ?? "pcmInt16") ?? .pcmInt16)
        let result: JSONValue = .object(["frames": .number(Double(generated.audio.frameCount)), "sampleRateHertz": .number(sampleRate.hertz), "output": .string(URL(fileURLWithPath: output).lastPathComponent)])
        emit(command: "generate-signal", value: result, json: args.has("json"), quiet: args.has("quiet"), message: "Generated \(generated.audio.frameCount) frames.")
    }

    private static func analyzeFiles(_ args: ParsedCLIArguments) async throws {
        let reference = try args.require("reference")
        let configuration = FileAnalysisConfiguration(channel: try args.int("channel") ?? 0,
            method: CorrelationMethod(rawValue: args.value("method") ?? "automatic") ?? .automatic,
            sampleRate: try args.double("sample-rate"), searchMinimum: try args.int64("search-min"), searchMaximum: try args.int64("search-max"),
            normalize: !args.has("no-normalize"), includeCorrelationSequence: args.has("include-correlation"))
        if let directoryPath = args.value("input-directory") {
            let directory = URL(fileURLWithPath: directoryPath).standardizedFileURL
            let recordings = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).filter { $0.pathExtension.lowercased() == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !recordings.isEmpty else { throw CLIError.input("No WAV files were found in --input-directory.") }
            var values: [JSONValue] = []; var failures = 0
            for recording in recordings {
                do { let value = try await HeadlessFileAnalyzer().analyze(referenceURL: URL(fileURLWithPath: reference), recordingURL: recording, configuration: configuration); values.append(.object(["file": .string(recording.lastPathComponent), "status": .string("completed"), "result": try JSONValue.from(try JSONEncoder.cli.encode(value))])); if let outputDirectory = args.value("output-directory") { let directoryURL = URL(fileURLWithPath: outputDirectory); try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true); let resultURL = directoryURL.appendingPathComponent(recording.deletingPathExtension().lastPathComponent + ".json"); try ensureWritable(resultURL, overwrite: args.has("overwrite")); try JSONEncoder.cli.encode(value).write(to: resultURL, options: .atomic) } }
                catch { failures += 1; values.append(.object(["file": .string(recording.lastPathComponent), "status": .string("failed"), "error": .string(error.localizedDescription)])); if !args.has("continue-on-error") { break } }
            }
            emit(command: "analyze-files", value: .object(["mode": .string("batch"), "fileCount": .number(Double(recordings.count)), "failureCount": .number(Double(failures)), "results": .array(values)]), json: args.has("json"), quiet: args.has("quiet"), message: "Analyzed \(recordings.count - failures) files; \(failures) failed.")
            return
        }
        let recording = try args.require("recording")
        let result = try await HeadlessFileAnalyzer().analyze(referenceURL: URL(fileURLWithPath: reference), recordingURL: URL(fileURLWithPath: recording), configuration: configuration)
        let encoded = try JSONEncoder.cli.encode(result)
        if let output = args.value("output") { let outputURL = URL(fileURLWithPath: output).standardizedFileURL; try ensureWritable(outputURL, overwrite: args.has("overwrite")); try encoded.write(to: outputURL, options: .atomic) }
        if args.has("json") { print(String(decoding: encoded, as: UTF8.self)) }
        else if !args.has("quiet") { print("Delay: \(result.delayMilliseconds) ms (\(result.integerSampleDelay) samples), confidence \(result.confidence)") }
    }

    private static func listDevices(_ args: ParsedCLIArguments) async throws {
        let devices = try await SystemAudioDeviceService().devices()
        let result: JSONValue = .array(devices.map { device in .object(["uid": .string(device.id), "name": .string(device.name), "manufacturer": device.descriptor.manufacturer.map(JSONValue.string) ?? .null, "transport": .string(device.descriptor.transport.rawValue), "inputChannels": .number(Double(device.inputChannelCount)), "outputChannels": .number(Double(device.outputChannelCount)), "sampleRateHertz": .number(device.nominalSampleRate.hertz), "defaultInput": .bool(device.isDefaultInput), "defaultOutput": .bool(device.isDefaultOutput)]) })
        emit(command: "devices", value: result, json: args.has("json"), quiet: args.has("quiet"), message: "Found \(devices.count) devices.")
    }

    private static func deviceInfo(_ args: ParsedCLIArguments) async throws {
        let devices = try await SystemAudioDeviceService().devices()
        let matches = devices.filter { device in
            if let uid = args.value("uid") { return device.id == uid }
            if let name = args.value("name") { return device.name == name }
            if let contains = args.value("name-contains") { return device.name.localizedCaseInsensitiveContains(contains) }
            return device.isDefaultInput || device.isDefaultOutput
        }
        guard matches.count == 1 else { throw CLIError.input(matches.isEmpty ? "No device matched the selector." : "Selector matched \(matches.count) devices; use --uid or an exact --name.") }
        let device = matches[0]
        let data = try JSONEncoder.cli.encode(device)
        if args.has("json") { print(String(decoding: data, as: UTF8.self)) } else { print("\(device.name) [\(device.id)] \(device.nominalSampleRate.hertz) Hz, input \(device.inputChannelCount), output \(device.outputChannelCount)") }
    }

    private static func history(_ args: ParsedCLIArguments) async throws {
        let database = try args.require("database")
        let repository = try SQLiteMeasurementRepository(databaseURL: URL(fileURLWithPath: database))
        let page = try await repository.runs(matching: MeasurementHistoryQuery(searchText: args.value("search") ?? "", pageSize: try args.int("limit") ?? 50))
        let data = try JSONEncoder.cli.encode(page)
        if args.has("json") { print(String(decoding: data, as: UTF8.self)) } else { print("\(page.runs.count) of \(page.totalCount) history runs") }
    }

    private static func exportReport(_ args: ParsedCLIArguments) async throws {
        let input = try args.require("input"); let output = try args.require("output")
        guard let format = ReportExportFormat(rawValue: args.value("format") ?? "json") else { throw CLIError.usage("--format must be json, csv, html, pdf, or png.") }
        let document = try JSONCodec.decode(Data(contentsOf: URL(fileURLWithPath: input)))
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        try ensureWritable(outputURL, overwrite: args.has("overwrite"))
        let urls = try await ReportExporter.write(document: document, format: format, to: outputURL)
        emit(command: "export-report", value: .object(["files": .array(urls.map { .string($0.lastPathComponent) })]), json: args.has("json"), quiet: args.has("quiet"), message: urls.map(\.path).joined(separator: "\n"))
    }

    private static func runPlan(_ args: ParsedCLIArguments) async throws {
        let input = try args.require("config")
        let decoder = JSONDecoder(); let plan = try decoder.decode(AutomationPlan.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        guard plan.schemaVersion == AutomationPlan.schemaVersion else { throw CLIError.usage("Unsupported plan schema \(plan.schemaVersion).") }
        var results: [JSONValue] = []; var failures = 0
        for task in plan.tasks {
            do {
                guard task.operation == "file-analysis", let reference = task.referenceFile, let recording = task.recordingFile else { throw CLIError.unsupported("Only file-analysis tasks are currently executable in run-plan.") }
                let value = try await HeadlessFileAnalyzer().analyze(referenceURL: URL(fileURLWithPath: reference), recordingURL: URL(fileURLWithPath: recording), configuration: task.configuration ?? .init())
                results.append(.object(["operation": .string(task.operation), "status": .string("completed"), "result": try JSONValue.from(try JSONEncoder.cli.encode(value))]))
            } catch {
                failures += 1; results.append(.object(["operation": .string(task.operation), "status": .string("failed"), "error": .string(error.localizedDescription)]))
                if plan.failurePolicy == .stop { break }
            }
        }
        emit(command: "run-plan", value: .object(["schemaVersion": .string("1.0"), "taskCount": .number(Double(plan.tasks.count)), "failureCount": .number(Double(failures)), "results": .array(results)]), json: args.has("json"), quiet: args.has("quiet"), message: "Completed \(plan.tasks.count - failures) tasks; \(failures) failed.")
    }

    private static func validateInput(_ args: ParsedCLIArguments) throws {
        let input = try args.require("input")
        let inputURL = URL(fileURLWithPath: input).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue, inputURL.pathExtension == "audiolinkbundle" {
            let validation = try AudioLinkBundleValidator().validate(inputURL)
            let result: JSONValue = .object([
                "valid": .bool(validation.isValid),
                "bundleID": validation.bundleID.map { .string($0.uuidString) } ?? .null,
                "checkedFileCount": .number(Double(validation.checkedFileCount)),
                "totalBytes": .number(Double(validation.totalBytes)),
                "errors": .array(validation.errors.map(JSONValue.string)),
                "warnings": .array(validation.warnings.map(JSONValue.string))
            ])
            guard validation.isValid else {
                let details = validation.errors.prefix(3).joined(separator: " ")
                throw CLIError.input("The bundle failed integrity validation. \(details)")
            }
            emit(command: "validate", value: result, json: args.has("json"), quiet: args.has("quiet"), message: "Bundle is valid.")
            return
        }
        let data = try Data(contentsOf: inputURL)
        let result = try JSONDecoder().decode(HeadlessFileAnalysisResult.self, from: data)
        let valid = result.schemaVersion == HeadlessFileAnalysisResult.schemaVersion && result.sampleRateHertz.isFinite && result.confidence.isFinite
        guard valid else { throw CLIError.input("The input result failed schema or finite-number validation.") }
        emit(command: "validate", value: .object(["valid": .bool(true), "schemaVersion": .string(result.schemaVersion)]), json: args.has("json"), quiet: args.has("quiet"), message: "Input is valid.")
    }

    private static func estimateDrift(_ args: ParsedCLIArguments) throws {
        let input = try args.require("input")
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let observations: [DriftObservation]
        if let wrapped = try? JSONDecoder().decode([String: [DriftObservation]].self, from: data), let values = wrapped["observations"] { observations = values }
        else { observations = try JSONDecoder().decode([DriftObservation].self, from: data) }
        let estimate = try ClockDriftEstimator().estimate(observations: observations)
        let encoded = try JSONEncoder.cli.encode(estimate)
        if args.has("json") { print(String(decoding: encoded, as: UTF8.self)) } else if !args.has("quiet") { print("Drift: \(estimate.driftPPM) ppm; offset \(estimate.constantOffsetSamples) samples; confidence \(estimate.confidence)") }
    }

    private static func emit(command: String, value: JSONValue, json: Bool, quiet: Bool, message: String) {
        if json { let output = CLIOutput(schemaVersion: "1.0", command: command, status: "completed", result: value, error: nil); print(String(decoding: (try? JSONEncoder.cli.encode(output)) ?? Data("{}".utf8), as: UTF8.self)) }
        else if !quiet { print(message) }
    }
    private static func ensureWritable(_ url: URL, overwrite: Bool) throws {
        if FileManager.default.fileExists(atPath: url.path), !overwrite { throw CLIError.input("Output already exists: \(url.lastPathComponent). Pass --overwrite to replace it.") }
    }
    private static func emitError(_ error: Error, json: Bool) {
        if json { let output = CLIOutput(schemaVersion: "1.0", command: CommandLine.arguments.dropFirst().first ?? "unknown", status: "failed", result: nil, error: error.localizedDescription); print(String(decoding: (try? JSONEncoder.cli.encode(output)) ?? Data("{}".utf8), as: UTF8.self)) }
        fputs("audiolink: \(error.localizedDescription)\n", stderr)
    }
    private static func code(for error: Error) -> CLIExitCode {
        guard let cliError = error as? CLIError else { return .execution }
        switch cliError { case .usage: return .usage; case .input: return .input; case .unsupported: return .unsupported; case .execution: return .execution }
    }
    private static func printHelp() {
        print("""
        audiolink — headless AudioLink Lab automation

        Commands:
          devices | device-info | generate-signal | analyze-files
          measure-loopback | benchmark-device | profile-plugin | analyze-path
          estimate-drift | export-report | validate | history | run-plan

        Common options: --input PATH --output PATH --sample-rate HZ --buffer-size N
          --channel N --format VALUE --json --quiet --verbose --timeout SECONDS
          --config PATH --output-directory PATH --no-save --overwrite --help

        File analysis:
          audiolink analyze-files --reference REF.wav --recording TAKE.wav --json
          audiolink analyze-files --reference REF.wav --input-directory recordings --continue-on-error --json
        Generate a signal:
          audiolink generate-signal --output sweep.wav --sample-rate 48000 --duration 2

        Exit codes: 0 success, 2 usage, 3 input/selector, 4 unsupported capability,
        5 cancellation, 6 execution failure. JSON mode writes only one JSON document
        to stdout; diagnostics go to stderr.
        """)
    }
}

private extension ParsedCLIArguments {
    func int64(_ key: String) throws -> Int64? { guard let value = options[key] else { return nil }; guard let number = Int64(value) else { throw CLIError.usage("Invalid integer for --\(key): \(value)") }; return number }
}

private extension JSONEncoder {
    static let cli: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601; return encoder }()
}

private extension JSONValue {
    static func from(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
}
