import AudioLinkCore
import XCTest
@testable import AudioLinkRealtime

final class LongTermStabilityTests: XCTestCase {
    func testPlanSchedulesEventsAndRejectsInvalidTiming() throws {
        let plan = LongTermStabilityPlan(
            duration: try DurationSeconds(30),
            interval: try DurationSeconds(10)
        )
        XCTAssertEqual(plan.scheduledEventCount, 4)
        XCTAssertNoThrow(try plan.validate())

        let invalid = LongTermStabilityPlan(
            duration: try DurationSeconds(1),
            interval: try DurationSeconds(0)
        )
        XCTAssertThrowsError(try invalid.validate())
    }

    func testDurationAndIntervalUseExplicitSeconds() throws {
        let plan = LongTermStabilityPlan(
            duration: try DurationSeconds(61),
            interval: try DurationSeconds(15)
        )
        XCTAssertEqual(plan.scheduledEventCount, 5)
        XCTAssertEqual(plan.duration.value, 61)
        XCTAssertEqual(plan.interval.value, 15)
    }
}
