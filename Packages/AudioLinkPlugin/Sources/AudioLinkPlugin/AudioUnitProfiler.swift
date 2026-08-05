import Foundation

public actor AudioUnitProfiler {
    private let runner: any AudioUnitPluginRunner
    private let timeout: Duration
    public init(runner: any AudioUnitPluginRunner, timeout: Duration = .seconds(10)) { self.runner = runner; self.timeout = timeout }

    public func profile(plugin: AudioUnitDescriptor, configuration: PluginTestConfiguration) async throws -> PluginProfileResult {
        let frameCount = max(1, Int(configuration.sampleRate.hertz * configuration.durationSeconds))
        let input = [Float(configuration.inputAmplitude)] + Array(repeating: Float.zero, count: max(0, frameCount - 1))
        let request = AudioUnitHelperRequest(plugin: plugin.identity, configuration: configuration)
        let started = ContinuousClock.now
        let runner = self.runner
        let timeout = self.timeout
        let response = try await withThrowingTaskGroup(of: AudioUnitHelperResponse.self) { group in
            group.addTask { try await runner.render(input, request: request) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AudioUnitProfilerError.timeout
            }
            guard let first = try await group.next() else { throw AudioUnitProfilerError.timeout }
            group.cancelAll(); return first
        }
        guard response.status == .completed else { throw AudioUnitProfilerError.invalidOutput(response.status.rawValue) }
        guard response.output.allSatisfy(\.isFinite) else { throw AudioUnitProfilerError.invalidOutput("NaN or infinity") }
        let wall = started.duration(to: ContinuousClock.now).components
        let wallSeconds = Double(wall.seconds) + Double(wall.attoseconds) / 1e18
        let measured = response.output.firstIndex(where: { abs($0) > 0.000_1 }).map(Double.init)
        let latency = PluginLatencyResult(reportedFrames: plugin.reportedLatencyFrames, measuredFrames: measured)
        let rms = response.output.isEmpty ? 0 : sqrt(response.output.reduce(0) { $0 + Double($1 * $1) } / Double(response.output.count))
        return PluginProfileResult(plugin: plugin, configuration: configuration, latency: latency, noise: PluginNoiseResult(rms: rms, hasNonZeroIdleOutput: rms > 0), cpu: PluginCPUMetrics(renderedSeconds: configuration.durationSeconds, wallSeconds: wallSeconds), diagnostics: response.diagnostics)
    }
}
