import Foundation

public enum MockAudioUnitKind: String, Codable, Sendable { case passthrough, fixedDelay, gain, polarityInversion, lowPass, distortion, noise, longTail, nanOutput, crash, hang }

public struct MockAudioUnitPlugin: AudioUnitPluginRunner, Sendable {
    public let kind: MockAudioUnitKind
    public let delayFrames: Int
    public let gain: Float
    public init(kind: MockAudioUnitKind, delayFrames: Int = 0, gain: Float = 1) { self.kind = kind; self.delayFrames = max(0, delayFrames); self.gain = gain }

    public func render(_ input: [Float], request: AudioUnitHelperRequest) async throws -> AudioUnitHelperResponse {
        if kind == .hang { try await Task.sleep(for: .seconds(60)); throw AudioUnitProfilerError.timeout }
        if kind == .crash { throw AudioUnitProfilerError.crashed("mock helper crash") }
        var output = Array(repeating: Float.zero, count: input.count + delayFrames)
        for (index, sample) in input.enumerated() {
            let target = index + delayFrames
            guard target < output.count else { continue }
            switch kind {
            case .polarityInversion: output[target] = -sample
            case .gain: output[target] = sample * gain
            case .distortion: output[target] = tanh(sample * 3)
            case .noise: output[target] = sample + Float(sin(Double(index) * 12.9898) * 0.01)
            case .lowPass: output[target] = index == 0 ? sample : (sample + input[index - 1]) * 0.5
            case .nanOutput: output[target] = .nan
            case .longTail: output[target] = sample; if target + 1 < output.count { output[target + 1] += sample * 0.4 }
            default: output[target] = sample
            }
        }
        return AudioUnitHelperResponse(requestID: request.requestID, status: .completed, output: output)
    }
}
