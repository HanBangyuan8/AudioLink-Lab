import CoreGraphics

/// Centralized window and content thresholds for the macOS app.
///
/// The minimum window matches the native Latency shell. Content below the
/// comfortable thresholds changes topology instead of shrinking controls until
/// labels truncate or panels overlap.
enum AudioLinkLayoutMetrics {
    static let minimumWindowWidth: CGFloat = 1_100
    static let minimumWindowHeight: CGFloat = 760
    static let defaultWindowWidth: CGFloat = 1_180
    static let defaultWindowHeight: CGFloat = 820

    static let maximumMeasurementContentWidth: CGFloat = 1_080
    static let historySplitThreshold: CGFloat = 900
    static let pairedPanelMinimumWidth: CGFloat = 350
    static let pairedChartMinimumWidth: CGFloat = 320
    static let statisticCardMinimumWidth: CGFloat = 168

    static func historyUsesSplitLayout(availableWidth: CGFloat) -> Bool {
        availableWidth >= historySplitThreshold
    }

    static func preferredStatisticColumnCount(availableWidth: CGFloat) -> Int {
        max(1, min(4, Int((availableWidth + 10) / (statisticCardMinimumWidth + 10))))
    }
}
