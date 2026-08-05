import XCTest
import AudioLinkCore
@testable import AudioLinkSignalPath

final class SignalPathTests: XCTestCase {
    func testMarkerDetectionFindsOffset() {
        let id = UUID(); let marker = SignalPathMarkerGenerator.marker(kind: .main, version: "1", sessionID: id, sequence: 1, sampleRate: 48_000, frameCount: 128)
        let recording = Array(repeating: Float.zero, count: 40) + marker.samples + Array(repeating: Float.zero, count: 10)
        let detection = SignalPathMarkerDetector.detect(marker: marker, in: recording)
        XCTAssertTrue(detection.found); XCTAssertEqual(detection.sampleOffset, 40); XCTAssertGreaterThan(detection.correlation, 0.99)
    }

    func testMissingMarkerIsExplicit() {
        let marker = SignalPathMarkerGenerator.marker(kind: .sessionStart, version: "1", sessionID: UUID(), sequence: 0, sampleRate: 44_100, frameCount: 32)
        let detection = SignalPathMarkerDetector.detect(marker: marker, in: Array(repeating: Float.zero, count: 10))
        XCTAssertFalse(detection.found); XCTAssertNil(detection.sampleOffset)
    }

    func testWrongMarkerVersionIsRejected() {
        let marker = SignalPathMarkerGenerator.marker(kind: .main, version: "2", sessionID: UUID(), sequence: 0, sampleRate: 48_000, frameCount: 32)
        let detection = SignalPathMarkerDetector.detect(marker: marker, in: marker.samples, expectedVersion: "1")
        XCTAssertFalse(detection.found)
        XCTAssertFalse(detection.versionMatches)
    }

    func testComparisonWarnsOnSampleRateDifference() throws {
        let leftRate = try SampleRate(hertz: 48_000); let rightRate = try SampleRate(hertz: 44_100)
        let session = SignalPathSession(nodes: [], connections: [], configuration: SignalPathConfiguration(mode: .offlineFileRoundTrip, sampleRate: leftRate))
        let left = PathMeasurementResult(sessionID: session.id, measuredDelayFrames: 10, sampleRate: leftRate, checkpoints: [])
        let right = PathMeasurementResult(sessionID: session.id, measuredDelayFrames: 12, sampleRate: rightRate, checkpoints: [])
        XCTAssertTrue(PathComparison(left: left, right: right).warnings.contains("sampleRate differs"))
    }
}
