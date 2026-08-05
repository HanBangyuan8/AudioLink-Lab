import AudioLinkRealtimeSupport
import XCTest

final class RealtimeCaptureBufferTests: XCTestCase {
    func testBoundedCaptureBufferStopsAndReportsOverflowWithoutGrowing() {
        guard let buffer = al_recording_accumulator_create(8) else {
            return XCTFail("The bounded capture buffer could not be allocated")
        }
        defer { al_recording_accumulator_destroy(buffer) }

        let first: [Float] = [1, 2, 3, 4]
        first.withUnsafeBufferPointer { pointer in
            al_recording_accumulator_append(buffer, pointer.baseAddress, first.count, 1, 10)
        }
        let second: [Float] = [5, 6, 7, 8, 9]
        second.withUnsafeBufferPointer { pointer in
            al_recording_accumulator_append(buffer, pointer.baseAddress, second.count, 1, 14)
        }

        XCTAssertEqual(al_recording_accumulator_count(buffer), 8)
        XCTAssertEqual(al_recording_accumulator_overflow_count(buffer), 1)
        let outputCount = 8
        var output = [Float](repeating: 0, count: outputCount)
        output.withUnsafeMutableBufferPointer { pointer in
            al_recording_accumulator_copy(buffer, pointer.baseAddress, outputCount)
        }
        XCTAssertEqual(output, [1, 2, 3, 4, 5, 6, 7, 8])

        al_recording_accumulator_stop(buffer)
        let afterStop: [Float] = [10]
        afterStop.withUnsafeBufferPointer { pointer in
            al_recording_accumulator_append(buffer, pointer.baseAddress, 1, 1, 19)
        }
        XCTAssertEqual(al_recording_accumulator_count(buffer), 8)
        XCTAssertEqual(al_recording_accumulator_dropped_count(buffer), 1)
    }
}
