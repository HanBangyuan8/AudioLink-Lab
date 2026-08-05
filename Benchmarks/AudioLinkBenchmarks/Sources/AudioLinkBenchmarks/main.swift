import AudioLinkCore
import AudioLinkDSP
import AudioLinkNetworking
import AudioLinkReporting
import AudioLinkStorage
import Foundation
import Darwin

private struct BenchmarkRow: Codable {
    let operation: String
    let durationSeconds: Double
    let inputFrames: Int
    let inputBytes: Int
    let wallMilliseconds: Double
    let maximumResidentBytes: Int64
    let platform: String
}

private struct Options {
    let profile: String
    let output: URL
}

private enum BenchmarkError: Error {
    case transferMismatch
}

@main
private struct AudioLinkBenchmarks {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let profile = value(after: "--profile", in: arguments) ?? "quick"
        let output = URL(fileURLWithPath: value(after: "--output", in: arguments) ?? "Benchmarks/results/benchmark-summary.json").standardizedFileURL
        let durations: [Double] = profile == "full" ? [1, 10, 60] : [1, 10]
        var rows: [BenchmarkRow] = []
        for duration in durations {
            rows.append(try benchmarkSignal(duration: duration))
            rows.append(try await benchmarkCorrelation(duration: duration))
            rows.append(try await benchmarkQuality(duration: duration))
            rows.append(try await benchmarkResampling(duration: duration))
            rows.append(try benchmarkWaveformDownsampling(duration: duration))
        }
        rows.append(try await benchmarkSQLiteBulkInsert())
        rows.append(try await benchmarkReportExport())
        rows.append(try await benchmarkFileTransfer())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(rows).write(to: output, options: .atomic)
        print("Wrote \(rows.count) benchmark rows to \(output.path)")
    }

    private static func benchmarkSignal(duration: Double) throws -> BenchmarkRow {
        let rate = try SampleRate(hertz: 48_000)
        let configuration = TestSignalConfiguration(
            kind: .logarithmicSweep,
            sampleRate: rate,
            duration: try DurationSeconds(duration),
            startFrequencyHertz: 20,
            endFrequencyHertz: 20_000,
            amplitude: 0.5,
            fadeIn: try DurationSeconds(min(0.01, duration / 4)),
            fadeOut: try DurationSeconds(min(0.01, duration / 4))
        )
        var output: GeneratedSignal?
        let (milliseconds, resident) = try measure { output = try TestSignalGenerator().generate(configuration: configuration) }
        return row("signalGeneration", duration, output?.audio.frameCount ?? 0, (output?.audio.samples.count ?? 0) * MemoryLayout<Float>.stride, milliseconds, resident)
    }

    private static func benchmarkBuffers(duration: Double) throws -> (AudioSampleBuffer, AudioSampleBuffer) {
        let rate = try SampleRate(hertz: 48_000)
        let frames = max(1, Int(duration * rate.hertz))
        var generator = SplitMix64(seed: 0xA0D1_2026)
        let reference = (0..<frames).map { _ in Float(generator.next() * 0.7 - 0.35) }
        let observed = Array(repeating: Float(0), count: min(frames / 10, 4_800)) + reference + Array(repeating: Float(0), count: 64)
        let format = AudioFormatDescriptor(sampleRate: rate, channelCount: 1, bitDepth: 32, isInterleaved: false)
        return (try AudioSampleBuffer(samples: reference, format: format), try AudioSampleBuffer(samples: observed, format: format))
    }

    private static func benchmarkCorrelation(duration: Double) async throws -> BenchmarkRow {
        let (reference, observed) = try benchmarkBuffers(duration: duration)
        let (milliseconds, resident) = try await measureAsync { _ = try await DelayAnalysisEngine().analyze(reference: reference, observed: observed, configuration: CorrelationConfiguration(method: .fft, searchRange: SampleLagRange(minimum: 0, maximum: Int64(min(8_000, observed.frameCount - 1))), sequenceOutput: .none)) }
        return row("fftCorrelation", duration, observed.frameCount, observed.samples.count * MemoryLayout<Float>.stride, milliseconds, resident)
    }

    private static func benchmarkQuality(duration: Double) async throws -> BenchmarkRow {
        let (reference, observed) = try benchmarkBuffers(duration: duration)
        let referenceFile = imported(reference, name: "reference")
        let observedFile = imported(observed, name: "observed")
        let (milliseconds, resident) = try await measureAsync { _ = try await MeasurementQualityAnalyzer().analyze(reference: referenceFile, observed: observedFile, correlationConfiguration: CorrelationConfiguration(method: .fft, searchRange: SampleLagRange(minimum: 0, maximum: Int64(min(8_000, observed.frameCount - 1))), sequenceOutput: .none)) }
        return row("qualityAnalysis", duration, observed.frameCount, observed.samples.count * MemoryLayout<Float>.stride, milliseconds, resident)
    }

    private static func benchmarkResampling(duration: Double) async throws -> BenchmarkRow {
        let (reference, _) = try benchmarkBuffers(duration: duration)
        let importedFile = imported(reference, name: "resample")
        let target = try SampleRate(hertz: 44_100)
        let (milliseconds, resident) = try await measureAsync { _ = try await AudioPreprocessor().process(importedFile, configuration: PreprocessingConfiguration(targetSampleRate: target)) }
        return row("resampling", duration, reference.frameCount, reference.samples.count * MemoryLayout<Float>.stride, milliseconds, resident)
    }

    private static func benchmarkWaveformDownsampling(duration: Double) throws -> BenchmarkRow {
        let (reference, _) = try benchmarkBuffers(duration: duration)
        var bins: [WaveformEnvelopeBin] = []
        let (milliseconds, resident) = measure { bins = PlotDataDownsampler().waveformEnvelope(samples: reference.samples, maximumBinCount: 2_000) }
        return row("waveformDownsampling", duration, reference.frameCount, bins.count * MemoryLayout<Float>.stride * 2, milliseconds, resident)
    }

    private static func benchmarkSQLiteBulkInsert() async throws -> BenchmarkRow {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audiolink-bench-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteMeasurementRepository(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessions = (0..<100).map { index in
            MeasurementHistorySession(createdAt: now, updatedAt: now, name: "benchmark-\(index)", measurementType: .offlineFile, configurationPayload: Data("{}".utf8), configurationSummary: [:], appVersion: AudioLinkReleaseMetadata.appVersion, algorithmVersion: AudioLinkReleaseMetadata.algorithmVersion, runs: [])
        }
        let (milliseconds, resident) = try await measureAsync { try await repository.saveSessions(sessions) }
        return row("sqliteBulkInsert", 0, sessions.count, sessions.count * 512, milliseconds, resident)
    }

    private static func benchmarkReportExport() async throws -> BenchmarkRow {
        let example = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Examples/SyntheticReport.json")
        let document = try JSONCodec.decode(Data(contentsOf: example))
        var artifacts: [ReportArtifact] = []
        let (milliseconds, resident) = try await measureAsync { artifacts = try await ReportExporter.artifacts(for: document, format: .html) }
        return row("reportGeneration", 0, document.runs.count, artifacts.reduce(0) { $0 + $1.data.count }, milliseconds, resident)
    }

    private static func benchmarkFileTransfer() async throws -> BenchmarkRow {
        let (sender, receiver) = await InMemoryPeerTransport.pair()
        let bytes = Data(repeating: 0x5A, count: 1_048_576)
        var received: Data?
        let (milliseconds, resident) = try await measureAsync { try await sender.send(bytes); received = try await receiver.receive() }
        guard received == bytes else { throw BenchmarkError.transferMismatch }
        return row("inMemoryFileTransfer", 0, 0, bytes.count, milliseconds, resident)
    }

    private static func imported(_ buffer: AudioSampleBuffer, name: String) -> ImportedAudioFile {
        let analyzer = AudioMetricsAnalyzer()
        let rate = buffer.format.sampleRate
        return ImportedAudioFile(fileURL: URL(fileURLWithPath: "/\(name).wav"), fileName: "\(name).wav", originalFormat: AudioFileFormatDescription(container: .wav, encoding: .ieeeFloat, sampleRate: rate, channelCount: buffer.channelCount, bitDepth: 32, isInterleaved: false, isBigEndian: false, formatIdentifier: "lpcm"), audio: buffer, analysis: analyzer.analyze(buffer))
    }

    private static func row(_ operation: String, _ duration: Double, _ frames: Int, _ bytes: Int, _ milliseconds: Double, _ resident: Int64) -> BenchmarkRow { BenchmarkRow(operation: operation, durationSeconds: duration, inputFrames: frames, inputBytes: bytes, wallMilliseconds: milliseconds, maximumResidentBytes: resident, platform: "\(ProcessInfo.processInfo.operatingSystemVersionString); \(ProcessInfo.processInfo.machineHardwareName)") }

    private static func measure<T>(_ body: () throws -> T) rethrows -> (Double, Int64) { let clock = ContinuousClock(); let start = clock.now; _ = try body(); let elapsed = start.duration(to: clock.now); return (Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15, residentMemory()) }
    private static func measureAsync<T>(_ body: () async throws -> T) async rethrows -> (Double, Int64) { let clock = ContinuousClock(); let start = clock.now; _ = try await body(); let elapsed = start.duration(to: clock.now); return (Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15, residentMemory()) }
    private static func residentMemory() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        // macOS reports ru_maxrss in bytes (Linux reports KiB); this package
        // is intentionally macOS-only so the unit is stable in the JSON.
        return Int64(usage.ru_maxrss)
    }
    private static func value(after option: String, in arguments: [String]) -> String? { guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }; return arguments[index + 1] }
}

private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return Double(z ^ (z >> 31)) / Double(UInt64.max) }
}

private extension ProcessInfo {
    var machineHardwareName: String { ProcessInfo.processInfo.environment["HOSTTYPE"] ?? "unknown" }
}
