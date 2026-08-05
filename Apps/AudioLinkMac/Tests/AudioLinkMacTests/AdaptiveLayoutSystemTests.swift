import XCTest
@testable import AudioLinkMac

final class AdaptiveLayoutSystemTests: XCTestCase {
    func testWindowMinimumMatchesNativeShellRequirement() {
        XCTAssertEqual(AudioLinkLayoutMetrics.minimumWindowWidth, 1_100)
        XCTAssertEqual(AudioLinkLayoutMetrics.minimumWindowHeight, 760)
        XCTAssertGreaterThanOrEqual(
            AudioLinkLayoutMetrics.defaultWindowWidth,
            AudioLinkLayoutMetrics.minimumWindowWidth
        )
        XCTAssertGreaterThanOrEqual(
            AudioLinkLayoutMetrics.defaultWindowHeight,
            AudioLinkLayoutMetrics.minimumWindowHeight
        )
    }

    func testHistoryLayoutChangesOnlyAtCentralizedThreshold() {
        XCTAssertFalse(AudioLinkLayoutMetrics.historyUsesSplitLayout(availableWidth: 899.9))
        XCTAssertTrue(AudioLinkLayoutMetrics.historyUsesSplitLayout(availableWidth: 900))
    }

    func testStatisticColumnsAreBoundedAndResponsive() {
        XCTAssertEqual(AudioLinkLayoutMetrics.preferredStatisticColumnCount(availableWidth: 120), 1)
        XCTAssertEqual(AudioLinkLayoutMetrics.preferredStatisticColumnCount(availableWidth: 360), 2)
        XCTAssertEqual(AudioLinkLayoutMetrics.preferredStatisticColumnCount(availableWidth: 900), 4)
        XCTAssertEqual(AudioLinkLayoutMetrics.preferredStatisticColumnCount(availableWidth: 4_000), 4)
    }
}
