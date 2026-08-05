import AudioLinkSpatial
import AudioLinkCore
import XCTest

final class SpatialTests: XCTestCase {
    func testCoordinateConversionAndDistance() throws {
        let a = try SpatialCoordinate(x: 0, y: 0)
        let b = try SpatialCoordinate(x: 1, y: 0)
        XCTAssertEqual(a.distance(to: b), 1, accuracy: 1e-12)
        XCTAssertEqual(b.converted(to: .feet).x, 3.280839895013123, accuracy: 1e-9)
    }
    func testExtractionFindsDelayedImpulse() throws {
        let sweep: [Float] = [Float](repeating: 0, count: 8).enumerated().map { $0.offset == 0 ? 1 : 0 }
        let recording: [Float] = [Float](repeating: 0, count: 14).enumerated().map { $0.offset == 4 ? 1 : 0 }
        let ir = try ImpulseResponseAnalyzer().extractImpulseResponse(sweep: sweep, recording: recording, sampleRate: .hz48000)
        XCTAssertEqual(ir.indices.max { abs(ir[$0]) < abs(ir[$1]) }, 4)
    }
    func testInsufficientDecayDoesNotInventRT60() throws {
        let samples = [Float](repeating: 0, count: 128)
        var values = samples; values[0] = 1
        let metrics = try ImpulseResponseAnalyzer().analyze(samples: values, sampleRate: .hz48000)
        XCTAssertFalse(metrics.estimatedRT60.valid)
    }
    func testSchroederDecayUsesEnergyAndReportsFitConfidence() throws {
        let sampleRate = 48_000.0
        let targetRT60 = 0.05
        let count = 9_600
        let values = (0..<count).map { index -> Float in
            let time = Double(index) / sampleRate
            return Float(exp(-log(1_000) * time / targetRT60))
        }
        let metrics = try ImpulseResponseAnalyzer().analyze(samples: values, sampleRate: .hz48000)
        XCTAssertTrue(metrics.estimatedRT60.valid)
        XCTAssertEqual(metrics.estimatedRT60.value ?? .nan, targetRT60, accuracy: 0.01)
        XCTAssertGreaterThan(metrics.estimatedRT60.confidence, 0.85)
        XCTAssertTrue(metrics.c50.explanation.contains("after the detected direct sound"))
    }
    func testNonFiniteImpulseResponseIsRejected() throws {
        XCTAssertThrowsError(try ImpulseResponseAnalyzer().analyze(samples: [1, .nan], sampleRate: .hz48000)) { error in
            XCTAssertEqual(error as? SpatialValidationError, .invalidIR)
        }
    }
    func testNoiseFloorAboveRequestedDecayRangeInvalidatesRTMetrics() throws {
        let values = (0..<9_600).map { index -> Float in
            let time = Double(index) / 48_000
            return Float(exp(-log(1_000) * time / 0.05))
        }
        let metrics = try ImpulseResponseAnalyzer().analyze(
            samples: values,
            sampleRate: .hz48000,
            noiseSamples: [Float](repeating: 0.5, count: 9_600)
        )
        XCTAssertFalse(metrics.estimatedRT60.valid)
        XCTAssertTrue(metrics.estimatedRT60.explanation.contains("excessive noise floor"))
    }
    func testMapWarnsWhenSparse() throws {
        let c = try SpatialCoordinate(x: 0, y: 0)
        let sample = SpatialMapSample(positionID: UUID(), coordinate: c, metric: 1, valid: true)
        let map = SpatialMapBuilder().map(metricName: "RT60", samples: [sample], interpolate: true, grid: [c])
        XCTAssertNotNil(map.warning)
        XCTAssertTrue(map.interpolated.isEmpty)
    }
    func testOctaveBandAnalyzerRejectsAboveNyquistAndFindsBand() throws {
        let rate = SampleRate.hz48000
        let samples = (0..<4_800).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / rate.hertz)) }
        let bands = try [FrequencyBand.octave(centerHertz: 1_000), FrequencyBand.octave(centerHertz: 16_000), FrequencyBand(centerHertz: 30_000, lowerHertz: 29_000, upperHertz: 31_000, kind: .octave)]
        let result = try FrequencyBandAnalyzer().analyze(samples: samples, sampleRate: rate, bands: bands)
        XCTAssertTrue(result[0].valid)
        XCTAssertFalse(result[2].valid)
        XCTAssertGreaterThan(result[0].levelDecibels ?? -100, result[1].levelDecibels ?? -100)
    }
}
