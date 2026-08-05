import Foundation

public enum SignalPathMarkerGenerator {
    public static func marker(kind: SignalPathMarkerKind, version: String, sessionID: UUID, sequence: Int, sampleRate: Double, frameCount: Int = 256) -> SignalPathMarker {
        let seed = stableSeed(kind: kind, version: version, id: sessionID, sequence: sequence)
        let frequency = 200.0 + Double(seed % 1_000)
        let samples = (0..<max(8, frameCount)).map { index in
            let phase = Double(index) / sampleRate * frequency * 2 * .pi
            let window = min(1, min(Double(index) / 16, Double(frameCount - index) / 16))
            return Float(sin(phase) * max(0, window) * 0.25)
        }
        return SignalPathMarker(kind: kind, version: version, sessionID: sessionID, sequence: sequence, samples: samples)
    }

    public static func sequence(version: String, sessionID: UUID, sampleRate: Double, markerLength: Int = 256) -> [SignalPathMarker] {
        SignalPathMarkerKind.allCases.enumerated().map { marker(kind: $0.element, version: version, sessionID: sessionID, sequence: $0.offset, sampleRate: sampleRate, frameCount: markerLength) }
    }

    private static func stableSeed(kind: SignalPathMarkerKind, version: String, id: UUID, sequence: Int) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in ("\(kind.rawValue)|\(version)|\(id.uuidString)|\(sequence)").utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return hash
    }
}

public enum SignalPathMarkerDetector {
    public static func detect(marker: SignalPathMarker, in recording: [Float], threshold: Double = 0.55, expectedVersion: String? = nil) -> SignalPathMarkerDetection {
        let versionMatches = expectedVersion.map { $0 == marker.version } ?? true
        guard recording.count >= marker.samples.count, !marker.samples.isEmpty else { return SignalPathMarkerDetection(marker: marker.kind, sampleOffset: nil, correlation: 0, found: false, versionMatches: versionMatches) }
        let referenceEnergy = sqrt(marker.samples.reduce(0) { $0 + Double($1 * $1) })
        guard referenceEnergy > 0 else { return SignalPathMarkerDetection(marker: marker.kind, sampleOffset: nil, correlation: 0, found: false, versionMatches: versionMatches) }
        var best = -Double.greatestFiniteMagnitude
        var bestIndex: Int?
        for offset in 0...(recording.count - marker.samples.count) {
            var dot = 0.0; var energy = 0.0
            for index in marker.samples.indices { let sample = Double(recording[offset + index]); dot += sample * Double(marker.samples[index]); energy += sample * sample }
            guard energy > 0 else { continue }
            let value = dot / (sqrt(energy) * referenceEnergy)
            if value > best { best = value; bestIndex = offset }
        }
        return SignalPathMarkerDetection(marker: marker.kind, sampleOffset: bestIndex, correlation: max(0, best), found: best >= threshold && versionMatches, versionMatches: versionMatches)
    }

    public static func detectSequence(markers: [SignalPathMarker], recording: [Float], threshold: Double = 0.55, expectedVersion: String? = nil) -> [SignalPathMarkerDetection] { markers.map { detect(marker: $0, in: recording, threshold: threshold, expectedVersion: expectedVersion) } }
}
