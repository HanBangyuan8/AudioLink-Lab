import SwiftUI
import Charts
import AudioLinkCore
import AudioLinkStorage
import AudioLinkRealtime
import AudioLinkAdaptive
import AudioLinkSpatial
import AudioLinkDistributed
import Foundation
import AppKit
import UniformTypeIdentifiers

struct MeasurementRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let audioPathName: String
    let excitationSignal: String
    let latencyMs: Int?
    let jitterMilliseconds: Double?
    let clockDriftPPM: Double?
    let correlationConfidence: Double?
    let success: Bool
    let errorDescription: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        audioPathName: String,
        excitationSignal: String,
        latencyMs: Int?,
        jitterMilliseconds: Double? = nil,
        clockDriftPPM: Double? = nil,
        correlationConfidence: Double? = nil,
        success: Bool,
        errorDescription: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.audioPathName = audioPathName
        self.excitationSignal = excitationSignal
        self.latencyMs = latencyMs
        self.jitterMilliseconds = jitterMilliseconds
        self.clockDriftPPM = clockDriftPPM
        self.correlationConfidence = correlationConfidence
        self.success = success
        self.errorDescription = errorDescription
    }
}

struct StatsSummary {
    let lastLatency: Int?
    let avgLatency24h: Double?
    let jitterMilliseconds: Double?
    let clockDriftPPM: Double?
    let correlationConfidence: Double?
}

enum MeasurementRecordCSVFormatter {
    static func csv(records: [MeasurementRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = ["timestamp", "audio_path_name", "excitation_signal", "delay_ms", "success", "error_description"]
        let rows = records.map { record in
            [
                formatter.string(from: record.timestamp),
                record.audioPathName,
                record.excitationSignal,
                record.latencyMs.map(String.init) ?? "",
                record.success ? "true" : "false",
                record.errorDescription ?? ""
            ]
            .map(escape)
            .joined(separator: ",")
        }
        return ([header.joined(separator: ",")] + rows).joined(separator: "\n") + "\n"
    }

    static func escape(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return needsQuotes ? "\"\(escaped)\"" : escaped
    }
}

enum MeasurementHistoryManager {
    static func clearing(records: [MeasurementRecord], audioPathName: String) -> [MeasurementRecord] {
        let trimmed = audioPathName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        return records.filter { $0.audioPathName != trimmed }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        }
    }

}

enum MotionIntensity: String, CaseIterable, Identifiable {
    case enhanced
    case reduced
    case none

    var id: String { rawValue }
}

struct AccentColorOption: Identifiable, Hashable {
    let id: String
    let simplifiedName: String
    let traditionalName: String
    let englishName: String
    let color: Color

    func name(for language: AppLanguage) -> String {
        switch language {
        case .english: englishName
        case .simplifiedChinese: simplifiedName
        case .traditionalChinese: traditionalName
        }
    }

    static let all: [AccentColorOption] = [
        AccentColorOption(id: "red", simplifiedName: "红", traditionalName: "紅", englishName: "Red", color: Color(red: 0.90, green: 0.24, blue: 0.28)),
        AccentColorOption(id: "orange", simplifiedName: "橙", traditionalName: "橙", englishName: "Orange", color: Color(red: 0.94, green: 0.48, blue: 0.16)),
        AccentColorOption(id: "yellow", simplifiedName: "黄", traditionalName: "黃", englishName: "Yellow", color: Color(red: 0.90, green: 0.72, blue: 0.18)),
        AccentColorOption(id: "green", simplifiedName: "绿", traditionalName: "綠", englishName: "Green", color: Color(red: 0.22, green: 0.70, blue: 0.38)),
        AccentColorOption(id: "cyan", simplifiedName: "青", traditionalName: "青", englishName: "Cyan", color: Color(red: 0.10, green: 0.70, blue: 0.76)),
        AccentColorOption(id: "blue", simplifiedName: "蓝", traditionalName: "藍", englishName: "Blue", color: Color(red: 0.20, green: 0.48, blue: 0.92)),
        AccentColorOption(id: "purple", simplifiedName: "紫", traditionalName: "紫", englishName: "Purple", color: Color(red: 0.56, green: 0.34, blue: 0.88)),
        AccentColorOption(id: "pink", simplifiedName: "粉", traditionalName: "粉", englishName: "Pink", color: Color(red: 0.92, green: 0.34, blue: 0.62)),
        AccentColorOption(id: "rose", simplifiedName: "玫瑰", traditionalName: "玫瑰", englishName: "Rose", color: Color(red: 0.86, green: 0.30, blue: 0.42)),
        AccentColorOption(id: "amber", simplifiedName: "琥珀", traditionalName: "琥珀", englishName: "Amber", color: Color(red: 0.96, green: 0.58, blue: 0.18)),
        AccentColorOption(id: "lime", simplifiedName: "青柠", traditionalName: "青檸", englishName: "Lime", color: Color(red: 0.54, green: 0.76, blue: 0.22)),
        AccentColorOption(id: "mint", simplifiedName: "薄荷", traditionalName: "薄荷", englishName: "Mint", color: Color(red: 0.18, green: 0.72, blue: 0.56)),
        AccentColorOption(id: "teal", simplifiedName: "蓝绿", traditionalName: "藍綠", englishName: "Teal", color: Color(red: 0.12, green: 0.58, blue: 0.70)),
        AccentColorOption(id: "indigo", simplifiedName: "靛蓝", traditionalName: "靛藍", englishName: "Indigo", color: Color(red: 0.36, green: 0.38, blue: 0.86)),
        AccentColorOption(id: "darkGray", simplifiedName: "深灰", traditionalName: "深灰", englishName: "Dark Gray", color: Color(red: 0.36, green: 0.38, blue: 0.43)),
        AccentColorOption(id: "lightGray", simplifiedName: "浅灰", traditionalName: "淺灰", englishName: "Light Gray", color: Color(red: 0.72, green: 0.74, blue: 0.78))
    ]

    static func option(for id: String) -> AccentColorOption {
        all.first { $0.id == id } ?? all[6]
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        switch language {
        case .simplifiedChinese:
            simplified[key] ?? key
        case .traditionalChinese:
            traditional[key] ?? simplified[key] ?? key
        case .english:
            english[key] ?? key
        }
    }

    private static let simplified: [String: String] = [
        "控制": "测量控制", "状态": "测量状态", "当前节点": "当前音频链路", "监控节点数": "测量通道数", "监控状态": "测量状态",
        "运行中": "测量中", "已停止": "就绪", "开始监控": "开始测量", "停止监控": "停止测量", "立即探测": "单次测量",
        "刷新代理列表": "刷新音频设备", "删除历史数据": "删除历史数据", "Overview": "新建测量", "节点分页": "音频链路",
        "节点监控": "音频测量", "上次延迟": "上次延迟", "24h 平均延迟": "平均延迟", "24h 最高延迟": "时钟漂移",
        "24h 丢包率": "抖动", "24h 可用率": "相关峰置信度", "延迟曲线": "延迟曲线", "时间范围": "时间范围",
        "还没有延迟数据": "还没有测量数据", "点击“开始监控”或“立即探测”后，这里会开始画曲线。": "点击“开始测量”或“单次测量”后，这里会显示延迟曲线。",
        "最近记录": "最近测量记录", "清空历史": "清空历史", "时间": "时间", "节点": "音频链路", "结果": "结果", "成功": "成功",
        "失败": "失败", "延迟": "延迟", "说明": "说明", "设置": "设置", "从剪贴板读取": "从剪贴板读取", "未设置": "未设置",
        "已设置": "已设置", "清空": "清空", "自动监控代理组所有节点": "自动测量所有可用音频链路", "跟随代理组当前节点": "跟随系统默认音频设备",
        "代理组": "音频设备组", "手动多选节点": "手动选择音频链路", "勾选多个节点后，每轮采样都会分别记录，并在左侧节点分页中逐页查看。": "选择多个音频链路后，每轮测量都会分别记录，并在左侧逐页查看。",
        "探测目标": "激励信号", "数据点间隔": "测量间隔", "测速超时": "捕获窗口", "每点探测次数": "重复测量次数",
        "次，取最小值": "次，取稳健估计", "点击“刷新代理列表”后选择节点。": "点击“刷新音频设备”后选择链路。",
        "所有选择节点": "所有选择链路", "等待数据": "等待测量", "监控中": "测量中", "趋势": "趋势", "节点概览": "链路概览",
        "合并延迟曲线": "合并延迟曲线", "主要颜色": "主要颜色", "个手动节点": "条手动链路", "刷新代理目录失败": "刷新音频设备失败",
        "已取消": "已取消", "检查更新": "检查更新", "发现新版本 %@": "发现新版本 %@", "已经是最新版本": "已经是最新版本",
        "检查更新失败": "检查更新失败", "打开下载页": "打开下载页", "每日自动检查": "每日自动检查",
        "Language": "语言", "动态效果": "动态效果", "增强": "增强", "减弱": "减弱", "无动画": "无动画", "Input Device": "输入设备", "Output Device": "输出设备",
        "连接与认证": "音频路由", "监控节点": "测量链路", "探测参数": "测量参数",
        "测速中": "测量中", "已暂停：未测到": "已暂停：没有有效结果", "天": "天", "已清空全部历史": "已清空全部历史",
        "没有可清理的历史": "没有可清理的历史", "历史已清理": "历史已清理", "导出 CSV": "导出 CSV",
        "已导出": "已导出", "导出失败": "导出失败", "数据库管理": "测量记录", "数据库大小": "记录大小",
        "数据库": "会话存储", "记录数": "记录数", "保留策略": "保留策略", "历史管理": "历史管理", "清理此节点": "清理此链路"
    ]
    private static let traditional: [String: String] = [
        "控制": "測量控制", "状态": "測量狀態", "当前节点": "目前音訊鏈路", "监控节点数": "測量通道數", "监控状态": "測量狀態",
        "运行中": "測量中", "已停止": "就緒", "开始监控": "開始測量", "停止监控": "停止測量", "立即探测": "單次測量",
        "刷新代理列表": "重新整理音訊裝置", "删除历史数据": "刪除歷史資料", "Overview": "新增測量", "节点分页": "音訊鏈路",
        "节点监控": "音訊測量", "上次延迟": "上次延遲", "24h 平均延迟": "平均延遲", "24h 最高延迟": "時鐘漂移",
        "24h 丢包率": "抖動", "24h 可用率": "相關峰值信心度", "延迟曲线": "延遲曲線", "时间范围": "時間範圍",
        "还没有延迟数据": "還沒有測量資料", "点击“开始监控”或“立即探测”后，这里会开始画曲线。": "點擊「開始測量」或「單次測量」後，這裡會顯示延遲曲線。",
        "最近记录": "最近測量記錄", "清空历史": "清空歷史", "时间": "時間", "节点": "音訊鏈路", "结果": "結果", "成功": "成功",
        "失败": "失敗", "延迟": "延遲", "说明": "說明", "设置": "設定", "从剪贴板读取": "從剪貼簿讀取", "未设置": "未設定",
        "已设置": "已設定", "清空": "清空", "自动监控代理组所有节点": "自動測量所有可用音訊鏈路", "跟随代理组当前节点": "跟隨系統預設音訊裝置",
        "代理组": "音訊裝置群組", "手动多选节点": "手動選擇音訊鏈路", "勾选多个节点后，每轮采样都会分别记录，并在左侧节点分页中逐页查看。": "選擇多個音訊鏈路後，每輪測量都會分別記錄，並在左側逐頁查看。",
        "探测目标": "激勵訊號", "数据点间隔": "測量間隔", "测速超时": "擷取視窗", "每点探测次数": "重複測量次數",
        "次，取最小值": "次，取穩健估計", "点击“刷新代理列表”后选择节点。": "點擊「重新整理音訊裝置」後選擇鏈路。",
        "所有选择节点": "所有選擇鏈路", "等待数据": "等待測量", "监控中": "測量中", "趋势": "趨勢", "节点概览": "鏈路總覽",
        "合并延迟曲线": "合併延遲曲線", "主要颜色": "主要顏色", "个手动节点": "條手動鏈路", "刷新代理目录失败": "重新整理音訊裝置失敗",
        "已取消": "已取消", "检查更新": "檢查更新", "发现新版本 %@": "發現新版本 %@", "已经是最新版本": "已經是最新版本",
        "检查更新失败": "檢查更新失敗", "打开下载页": "打開下載頁", "每日自动检查": "每日自動檢查",
        "Language": "語言", "动态效果": "動態效果", "增强": "增強", "减弱": "減弱", "无动画": "無動畫", "Input Device": "輸入裝置", "Output Device": "輸出裝置",
        "连接与认证": "音訊路由", "监控节点": "測量鏈路", "探测参数": "測量參數",
        "测速中": "測量中", "已暂停：未测到": "已暫停：沒有有效結果", "天": "天", "已清空全部历史": "已清空全部歷史",
        "没有可清理的历史": "沒有可清理的歷史", "历史已清理": "歷史已清理", "导出 CSV": "匯出 CSV",
        "已导出": "已匯出", "导出失败": "匯出失敗", "数据库管理": "測量記錄", "数据库大小": "記錄大小",
        "数据库": "工作階段儲存", "记录数": "記錄數", "保留策略": "保留策略", "历史管理": "歷史管理", "清理此节点": "清理此鏈路"
    ]
    private static let english: [String: String] = [
        "控制": "Measurement", "状态": "Measurement Status", "当前节点": "Current Audio Path", "监控节点数": "Measurement Channels", "监控状态": "Measurement Status",
        "运行中": "Measuring", "已停止": "Ready", "开始监控": "Start Measurement", "停止监控": "Stop Measurement", "立即探测": "Measure Once",
        "刷新代理列表": "Refresh Audio Devices", "删除历史数据": "Delete History", "Overview": "New Measurement", "节点分页": "Audio Paths",
        "节点监控": "Audio Measurement", "上次延迟": "Last Delay", "24h 平均延迟": "Average Delay", "24h 最高延迟": "Clock Drift",
        "24h 丢包率": "Jitter", "24h 可用率": "Peak Confidence", "延迟曲线": "Delay Chart", "时间范围": "Time Range",
        "还没有延迟数据": "No measurement data yet", "点击“开始监控”或“立即探测”后，这里会开始画曲线。": "Start a measurement or measure once to populate the delay chart.",
        "最近记录": "Recent Measurement Runs", "清空历史": "Clear History", "时间": "Time", "节点": "Audio Path", "结果": "Result", "成功": "Success",
        "失败": "Failed", "延迟": "Latency", "说明": "Notes", "设置": "Settings", "从剪贴板读取": "Paste", "未设置": "Not set",
        "已设置": "Set", "清空": "Clear", "自动监控代理组所有节点": "Measure all available audio paths", "跟随代理组当前节点": "Follow system default audio devices",
        "代理组": "Audio Device Set", "手动多选节点": "Select Audio Paths", "勾选多个节点后，每轮采样都会分别记录，并在左侧节点分页中逐页查看。": "Selected audio paths are recorded separately and shown as pages in the sidebar.",
        "探测目标": "Excitation Signal", "数据点间隔": "Measurement Interval", "测速超时": "Capture Window", "每点探测次数": "Repetitions",
        "次，取最小值": "runs, robust estimate", "点击“刷新代理列表”后选择节点。": "Refresh audio devices, then select paths.",
        "所有选择节点": "All Selected Paths", "等待数据": "Waiting for measurement", "监控中": "Measuring", "趋势": "Trend", "节点概览": "Path Overview",
        "合并延迟曲线": "Combined Delay Chart", "主要颜色": "Accent Color", "个手动节点": "manual paths", "刷新代理目录失败": "Failed to refresh audio devices",
        "已取消": "Cancelled", "检查更新": "Check for Updates", "发现新版本 %@": "New version available: %@", "已经是最新版本": "Already up to date",
        "检查更新失败": "Update check failed", "打开下载页": "Open Download Page", "每日自动检查": "Daily automatic check",
        "Language": "Language", "动态效果": "Motion", "增强": "Enhanced", "减弱": "Reduced", "无动画": "Off", "Input Device": "Input Device", "Output Device": "Output Device",
        "连接与认证": "Audio Routing", "监控节点": "Measurement Paths", "探测参数": "Measurement Settings",
        "测速中": "Measuring", "已暂停：未测到": "Paused: no valid result", "天": "days", "已清空全部历史": "All history cleared",
        "没有可清理的历史": "No history to clear", "历史已清理": "History cleared", "导出 CSV": "Export CSV",
        "已导出": "Exported", "导出失败": "Export failed", "数据库管理": "Measurement Records", "数据库大小": "Record Size",
        "数据库": "Session Store", "记录数": "Records", "保留策略": "Retention", "历史管理": "History", "清理此节点": "Clear Path"
    ]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var inputDeviceName: String { didSet { UserDefaults.standard.set(inputDeviceName, forKey: "audiolink.inputDevice") } }
    @Published var outputDeviceName: String { didSet { UserDefaults.standard.set(outputDeviceName, forKey: "audiolink.outputDevice") } }
    @Published var audioPathName: String { didSet { UserDefaults.standard.set(audioPathName, forKey: "audiolink.primaryPath") } }
    @Published var manualAudioPathNames: String { didSet { UserDefaults.standard.set(manualAudioPathNames, forKey: "audiolink.manualPaths") } }
    @Published var excitationSignalName: String { didSet { UserDefaults.standard.set(excitationSignalName, forKey: "audiolink.excitationSignal") } }
    @Published var measurementIntervalMs: Int { didSet { UserDefaults.standard.set(measurementIntervalMs, forKey: "audiolink.measurementIntervalMs") } }
    @Published var captureWindowMs: Int { didSet { UserDefaults.standard.set(captureWindowMs, forKey: "audiolink.captureWindowMs") } }
    @Published var repetitionCount: Int { didSet { UserDefaults.standard.set(repetitionCount, forKey: "audiolink.repetitions") } }
    @Published var followSystemDefaultDevices: Bool { didSet { UserDefaults.standard.set(followSystemDefaultDevices, forKey: "audiolink.followDefaultDevices") } }
    @Published var measureAllAudioPaths: Bool { didSet { UserDefaults.standard.set(measureAllAudioPaths, forKey: "audiolink.measureAllPaths") } }
    @Published var deviceSetName: String { didSet { UserDefaults.standard.set(deviceSetName, forKey: "audiolink.deviceSet") } }
    @Published var languageCode: String { didSet { UserDefaults.standard.set(languageCode, forKey: "audiolink.languageCode") } }
    @Published var accentColorID: String { didSet { UserDefaults.standard.set(accentColorID, forKey: "audiolink.accentColorID") } }
    @Published var motionIntensityID: String { didSet { UserDefaults.standard.set(motionIntensityID, forKey: "audiolink.motionIntensityID") } }
    @Published var lastUpdateCheckAt: Double { didSet { UserDefaults.standard.set(lastUpdateCheckAt, forKey: "audiolink.lastUpdateCheckAt") } }

    @Published private(set) var recordsRevision = 0
    @Published var isRunning = false
    @Published var latestError: String?
    @Published var updateStatus: String?
    @Published var updateURL: URL?
    @Published var isCheckingForUpdates = false
    @Published var availableDeviceSets: [String] = []
    @Published var availableAudioPaths: [String] = []
    @Published var resolvedAudioPathName: String = "System Audio Path"
    @Published var monitoredAudioPathNames: [String] = ["System Audio Path"]
    @Published var isMeasuring = false
    @Published private(set) var lastMeasurementStartedAt: Date?
    @Published private(set) var lastMeasurementCompletedAt: Date?
    @Published private(set) var lastMeasurementAttemptCount = 0
    @Published private(set) var lastMeasurementSuccessCount = 0
    @Published var databaseStatusMessage: String?

    private var measurementLoopTask: Task<Void, Never>?
    private let dependencies: AudioLinkDependencies
    private let manualAudioPathSeparator = "\n"
    private(set) var records: [MeasurementRecord] = []
    private var recordIndex = MeasurementRecordIndex(records: [])
    private var statsCache: [MeasurementStatsCacheKey: StatsSummary] = [:]
    private var chartCache: [MeasurementChartCacheKey: [MeasurementRecord]] = [:]
    let runtimePlan = RuntimeFeaturePlan.current
    let newMeasurementViewModel: NewMeasurementViewModel
    let realtimeMeasurementViewModel: RealtimeMeasurementViewModel
    let repeatedMeasurementViewModel: RepeatedMeasurementViewModel
    let calibrationViewModel: CalibrationViewModel
    let longTermStabilityViewModel: LongTermStabilityViewModel
    let historyViewModel: MeasurementHistoryViewModel

    var runtimeProfile: RuntimeOptimizationProfile {
        runtimePlan.profile
    }

    var selectedManualAudioPathNames: [String] {
        manualAudioPathNames
            .components(separatedBy: manualAudioPathSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .simplifiedChinese
    }

    var accentColor: Color {
        AccentColorOption.option(for: accentColorID).color
    }

    var motionIntensity: MotionIntensity {
        MotionIntensity(rawValue: motionIntensityID) ?? .enhanced
    }

    var locale: Locale {
        Locale(identifier: language.localeIdentifier)
    }

    var monitoringStatusText: String {
        if isMeasuring {
            return t("测速中")
        }
        if isRunning {
            if lastMeasurementAttemptCount == 0, latestError?.isEmpty == false {
                return t("已暂停：未测到")
            }
            if lastMeasurementAttemptCount > 0 {
                return "\(t("运行中")) \(lastMeasurementSuccessCount)/\(lastMeasurementAttemptCount)"
            }
            return t("运行中")
        }
        return t("已停止")
    }

    var databaseSizeText: String {
        guard let info = historyViewModel.repositoryInfo else { return "SQLite" }
        return ByteCountFormatter.string(fromByteCount: info.databaseSizeBytes, countStyle: .file)
    }

    var retentionPolicyText: String {
        "\(runtimePlan.retentionDays) \(t("天"))"
    }

    var databaseRecordCountText: String {
        "\(historyViewModel.repositoryInfo?.runCount ?? records.count)"
    }

    func t(_ key: String) -> String {
        L10n.text(key, language: language)
    }

    func displayError(_ description: String) -> String {
        description
            .replacingOccurrences(of: "已取消", with: t("已取消"))
            .replacingOccurrences(of: "cancelled", with: t("已取消"), options: [.caseInsensitive])
            .replacingOccurrences(of: "canceled", with: t("已取消"), options: [.caseInsensitive])
    }

    private func localizedMeasurementError(_ error: MeasurementError) -> String {
        guard language != .english else { return error.userFacingDescription }
        switch error {
        case .audioEngineFailure:
            return language == .traditionalChinese
                ? "請在「新增測量」中切換到「Real-time」完成即時播放、錄製與分析。"
                : "请在“新建测量”中切换到“Real-time”完成实时播放、录音与分析。"
        case .storageFailure:
            return language == .traditionalChinese ? "無法讀取或儲存測量記錄。" : "无法读取或保存测量记录。"
        case .invalidConfiguration:
            return language == .traditionalChinese ? "測量設定無效。" : "测量配置无效。"
        case .audioDeviceUnavailable:
            return language == .traditionalChinese ? "所選音訊裝置不可用。" : "所选音频设备不可用。"
        case .insufficientSignal:
            return language == .traditionalChinese ? "錄製訊號不足，無法可靠測量。" : "录制信号不足，无法可靠测量。"
        case .correlationFailure:
            return language == .traditionalChinese ? "找不到可靠的相關峰值。" : "找不到可靠的相关峰。"
        case .networkingUnavailable:
            return language == .traditionalChinese ? "網路測量尚未啟用。" : "网络测量尚未启用。"
        case .cancelled:
            return t("已取消")
        }
    }

    init(dependencies: AudioLinkDependencies = .live()) {
        self.dependencies = dependencies
        self.newMeasurementViewModel = NewMeasurementViewModel(
            historyPersistence: LiveMeasurementHistoryPersistence(
                repository: dependencies.measurementRepository,
                audioContainerURL: dependencies.historyAudioContainerURL
            )
        )
        self.historyViewModel = MeasurementHistoryViewModel(
            repository: dependencies.measurementRepository
        )
        self.realtimeMeasurementViewModel = RealtimeMeasurementViewModel(
            deviceService: dependencies.realtimeDeviceService,
            runner: dependencies.realtimeMeasurementRunner,
            calibrationRepository: dependencies.measurementRepository
        )
        self.repeatedMeasurementViewModel = RepeatedMeasurementViewModel(
            deviceService: dependencies.realtimeDeviceService,
            controller: dependencies.repeatedMeasurementController
        )
        self.calibrationViewModel = CalibrationViewModel(
            repository: dependencies.measurementRepository,
            deviceService: dependencies.realtimeDeviceService
        )
        self.longTermStabilityViewModel = LongTermStabilityViewModel(
            controller: dependencies.longTermStabilityController,
            realtimeViewModel: self.realtimeMeasurementViewModel
        )
        let defaults = UserDefaults.standard
        self.inputDeviceName = defaults.string(forKey: "audiolink.inputDevice") ?? "System Default Input"
        self.outputDeviceName = defaults.string(forKey: "audiolink.outputDevice") ?? "System Default Output"
        self.audioPathName = defaults.string(forKey: "audiolink.primaryPath") ?? "System Audio Path"
        self.manualAudioPathNames = defaults.string(forKey: "audiolink.manualPaths") ?? "System Audio Path"
        self.excitationSignalName = defaults.string(forKey: "audiolink.excitationSignal") ?? "Sine Sweep"
        self.measurementIntervalMs = defaults.object(forKey: "audiolink.measurementIntervalMs") as? Int ?? 30000
        self.captureWindowMs = defaults.object(forKey: "audiolink.captureWindowMs") as? Int ?? 5000
        self.repetitionCount = defaults.object(forKey: "audiolink.repetitions") as? Int ?? 3
        self.followSystemDefaultDevices = defaults.object(forKey: "audiolink.followDefaultDevices") as? Bool ?? true
        self.measureAllAudioPaths = defaults.object(forKey: "audiolink.measureAllPaths") as? Bool ?? false
        self.deviceSetName = defaults.string(forKey: "audiolink.deviceSet") ?? "System Audio"
        self.languageCode = defaults.string(forKey: "audiolink.languageCode") ?? AppLanguage.simplifiedChinese.rawValue
        self.accentColorID = defaults.string(forKey: "audiolink.accentColorID") ?? "purple"
        self.motionIntensityID = defaults.string(forKey: "audiolink.motionIntensityID") ?? MotionIntensity.enhanced.rawValue
        self.lastUpdateCheckAt = defaults.object(forKey: "audiolink.lastUpdateCheckAt") as? Double ?? 0
        normalizeStoredChoices()
        self.records = []
        self.recordIndex = MeasurementRecordIndex(records: [])
        self.resolvedAudioPathName = audioPathName
        self.monitoredAudioPathNames = selectedManualAudioPathNames.isEmpty ? [audioPathName] : selectedManualAudioPathNames
        Task {
            await refreshAudioPathCatalog()
            await importSharedMeasurementHistory()
        }
    }

    private func importSharedMeasurementHistory() async {
        do {
            let sessions = try await dependencies.sessionStore.sessions()
            let existingIDs = Set(records.map(\.id))
            let imported = sessions.flatMap { session in
                session.runs.compactMap { run -> MeasurementRecord? in
                    guard !existingIDs.contains(run.id) else { return nil }
                    let milliseconds = run.delayEstimate.map { Int($0.duration.milliseconds.rounded()) }
                    return MeasurementRecord(
                        id: run.id,
                        timestamp: run.completedAt ?? run.startedAt,
                        audioPathName: session.name,
                        excitationSignal: session.configuration.signal.rawValue,
                        latencyMs: milliseconds,
                        jitterMilliseconds: session.statistics?.jitterStandardDeviation.milliseconds,
                        clockDriftPPM: session.statistics?.clockDrift?.rawValue,
                        correlationConfidence: run.correlation?.confidence ?? run.delayEstimate?.confidence,
                        success: milliseconds != nil && run.error == nil,
                        errorDescription: run.error.map(localizedMeasurementError)
                    )
                }
            }
            guard !imported.isEmpty else { return }
            records.append(contentsOf: imported)
            records.sort { $0.timestamp < $1.timestamp }
            recordIndex.replace(with: records)
            invalidateRecordDerivedState()
        } catch {
            latestError = localizedMeasurementError(.storageFailure(ErrorContext(error: error)))
        }
    }

    private func deleteSharedMeasurementHistory() async {
        do {
            for session in try await dependencies.sessionStore.sessions() {
                try await dependencies.sessionStore.deleteSession(id: session.id)
            }
        } catch {
            latestError = localizedMeasurementError(.storageFailure(ErrorContext(error: error)))
        }
    }

    deinit {
        measurementLoopTask?.cancel()
    }

    func startMonitoring() {
        guard !isRunning else { return }
        isRunning = true
        latestError = nil
        scheduleMonitoringLoop()
    }

    func stopMonitoring() {
        isRunning = false
        measurementLoopTask?.cancel()
        measurementLoopTask = nil
    }

    func rescheduleMonitoringIfNeeded() {
        guard isRunning else { return }
        scheduleMonitoringLoop()
    }

    private func normalizeStoredChoices() {
        let allowedIntervals = [5000, 10000, 30000, 60000, 120000]
        if !allowedIntervals.contains(measurementIntervalMs) {
            measurementIntervalMs = allowedIntervals.min(by: { abs($0 - measurementIntervalMs) < abs($1 - measurementIntervalMs) }) ?? 5000
        }
        repetitionCount = min(5, max(1, repetitionCount))
    }

    func clearHistory() {
        records.removeAll()
        recordIndex.replace(with: records)
        invalidateRecordDerivedState()
        Task { await deleteSharedMeasurementHistory() }
        databaseStatusMessage = t("已清空全部历史")
    }

    func clearHistory(for audioPathName: String) {
        let trimmed = audioPathName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let originalCount = records.count
        let nextRecords = MeasurementHistoryManager.clearing(records: records, audioPathName: trimmed)
        guard nextRecords.count != originalCount else {
            databaseStatusMessage = "\(trimmed): \(t("没有可清理的历史"))"
            return
        }
        records = nextRecords
        recordIndex.replace(with: records)
        invalidateRecordDerivedState()
        databaseStatusMessage = "\(trimmed): \(t("历史已清理"))"
    }

    func exportHistoryCSV() {
        let panel = NSSavePanel()
        panel.title = t("导出 CSV")
        panel.nameFieldStringValue = "audiolink-history-\(Self.exportTimestamp()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MeasurementRecordCSVFormatter.csv(records: records).write(to: url, atomically: true, encoding: .utf8)
            databaseStatusMessage = "\(t("已导出")) \(url.lastPathComponent)"
        } catch {
            databaseStatusMessage = "\(t("导出失败"))：\(error.localizedDescription)"
        }
    }

    func setManualAudioPath(_ audioPath: String, isSelected: Bool) {
        var selected = selectedManualAudioPathNames
        if isSelected {
            if !selected.contains(audioPath) {
                selected.append(audioPath)
            }
        } else {
            selected.removeAll { $0 == audioPath }
        }
        manualAudioPathNames = selected.joined(separator: manualAudioPathSeparator)
        if !followSystemDefaultDevices && !measureAllAudioPaths {
            monitoredAudioPathNames = selected.isEmpty ? ["System Audio Path"] : selected
            resolvedAudioPathName = monitoredAudioPathNames.count == 1 ? monitoredAudioPathNames[0] : "\(monitoredAudioPathNames.count) \(t("个手动节点"))"
        }
    }

    func refreshAudioPathCatalog() async {
        let defaultPath = audioPathName(input: inputDeviceName, output: outputDeviceName)
        availableDeviceSets = ["System Audio", "Custom Routing"]
        availableAudioPaths = Array(Set([defaultPath, audioPathName] + selectedManualAudioPathNames)).sorted()

        if measureAllAudioPaths {
            monitoredAudioPathNames = availableAudioPaths
        } else if followSystemDefaultDevices {
            monitoredAudioPathNames = [defaultPath]
        } else {
            monitoredAudioPathNames = selectedManualAudioPathNames.isEmpty ? [defaultPath] : selectedManualAudioPathNames
        }
        resolvedAudioPathName = monitoredAudioPathNames.count == 1
            ? monitoredAudioPathNames[0]
            : "\(monitoredAudioPathNames.count) \(t("个手动节点"))"
        latestError = nil
    }

    func runMeasurement() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        let batchStartedAt = Date()
        let wasMonitoring = isRunning
        lastMeasurementStartedAt = batchStartedAt

        do {
            await refreshAudioPathCatalog()
            let configuration = try measurementConfiguration()
            let run = try await dependencies.measurementPerformer.measure(configuration: configuration)
            let session = MeasurementSession(
                createdAt: batchStartedAt,
                name: resolvedAudioPathName,
                configuration: configuration,
                runs: [run]
            )
            try await dependencies.sessionStore.save(session)
            let milliseconds = run.delayEstimate.map { Int($0.duration.milliseconds.rounded()) }
            append([
                MeasurementRecord(
                    id: run.id,
                    timestamp: run.completedAt ?? run.startedAt,
                    audioPathName: resolvedAudioPathName,
                    excitationSignal: excitationSignalName,
                    latencyMs: milliseconds,
                    correlationConfidence: run.correlation?.confidence ?? run.delayEstimate?.confidence,
                    success: milliseconds != nil && run.error == nil,
                    errorDescription: run.error.map(localizedMeasurementError)
                )
            ])
            lastMeasurementAttemptCount = 1
            lastMeasurementSuccessCount = milliseconds == nil ? 0 : 1
            lastMeasurementCompletedAt = Date()
            latestError = run.error.map(localizedMeasurementError)
        } catch {
            let measurementError = error as? MeasurementError ?? MeasurementError.audioEngineFailure(ErrorContext(error: error))
            let failedRun = MeasurementRun(
                startedAt: batchStartedAt,
                completedAt: Date(),
                error: measurementError
            )
            if let configuration = try? measurementConfiguration() {
                let session = MeasurementSession(
                    createdAt: batchStartedAt,
                    name: resolvedAudioPathName,
                    configuration: configuration,
                    runs: [failedRun]
                )
                try? await dependencies.sessionStore.save(session)
            }
            lastMeasurementAttemptCount = 1
            lastMeasurementSuccessCount = 0
            lastMeasurementCompletedAt = Date()
            append([
                MeasurementRecord(
                    id: failedRun.id,
                    timestamp: failedRun.completedAt ?? batchStartedAt,
                    audioPathName: resolvedAudioPathName,
                    excitationSignal: excitationSignalName,
                    latencyMs: nil,
                    success: false,
                    errorDescription: localizedMeasurementError(measurementError)
                )
            ])
            latestError = localizedMeasurementError(measurementError)
            if wasMonitoring {
                stopMonitoringAfterMeasurementSetupFailure()
            }
        }
    }

    private func measurementConfiguration() throws -> MeasurementConfiguration {
        let signal: MeasurementConfiguration.ExcitationSignal
        switch excitationSignalName {
        case "Impulse": signal = .impulse
        case "Maximum-Length Sequence": signal = .maximumLengthSequence
        default: signal = .sineSweep
        }
        let input = DeviceDescriptor(
            id: "input:\(inputDeviceName)",
            name: inputDeviceName,
            supportsInput: true,
            supportsOutput: false
        )
        let output = DeviceDescriptor(
            id: "output:\(outputDeviceName)",
            name: outputDeviceName,
            supportsInput: false,
            supportsOutput: true
        )
        return MeasurementConfiguration(
            format: AudioFormatDescriptor(
                sampleRate: .hz48000,
                channelCount: 1,
                bitDepth: 32,
                isInterleaved: false
            ),
            signal: signal,
            measurementDuration: try DurationSeconds(Double(captureWindowMs) / 1_000),
            repetitions: max(1, repetitionCount),
            inputDevice: input,
            outputDevice: output
        )
    }

    private func audioPathName(input: String, output: String) -> String {
        "\(output) → \(input)"
    }

    func stats(for audioPath: String? = nil) -> StatsSummary {
        stats(for: audioPath.map { [$0] })
    }

    func stats(for audioPaths: [String]?) -> StatsSummary {
        let key = MeasurementStatsCacheKey(
            audioPaths: normalizedAudioPathKey(audioPaths),
            minuteBucket: currentMinuteBucket()
        )
        if let cached = statsCache[key] {
            return cached
        }

        let summary = recordIndex.stats(for: audioPaths)
        statsCache[key] = summary
        return summary
    }

    func chartData(
        hours: Double = 24,
        audioPath: String? = nil,
        maxTotalPoints: Int? = nil,
        minimumPointsPerSeries: Int = 220
    ) -> [MeasurementRecord] {
        chartData(
            hours: hours,
            audioPaths: audioPath.map { [$0] },
            maxTotalPoints: maxTotalPoints,
            minimumPointsPerSeries: minimumPointsPerSeries
        )
    }

    func chartData(
        hours: Double = 24,
        audioPaths: [String]?,
        maxTotalPoints: Int? = nil,
        minimumPointsPerSeries: Int = 220
    ) -> [MeasurementRecord] {
        let maxPoints = maxTotalPoints ?? defaultChartPointBudget(hours: hours)
        let key = MeasurementChartCacheKey(
            hours: hours,
            audioPaths: normalizedAudioPathKey(audioPaths),
            maxTotalPoints: maxPoints,
            minimumPointsPerSeries: minimumPointsPerSeries,
            minuteBucket: currentMinuteBucket()
        )
        if let cached = chartCache[key] {
            return cached
        }

        let data = recordIndex.chartData(
            hours: hours,
            audioPaths: audioPaths,
            maxTotalPoints: maxPoints,
            minimumPointsPerSeries: minimumPointsPerSeries
        )
        chartCache[key] = data
        return data
    }

    func recentRecords(for audioPath: String? = nil, limit: Int) -> [MeasurementRecord] {
        recordIndex.recentRecords(for: audioPath, limit: limit)
    }

    func audioPathChartPointBudget(hours: Double) -> Int {
        if hours <= 4 { return runtimeProfile.nodeChartBudgetSmallRange }
        if hours <= 24 { return runtimeProfile.nodeChartBudgetDayRange }
        if hours <= 168 { return runtimeProfile.nodeChartBudgetWeekRange }
        return runtimeProfile.nodeChartBudgetLongRange
    }

    func overviewChartPointBudget(hours: Double, seriesCount: Int) -> Int {
        let basePerSeries: Int
        if hours <= 4 {
            basePerSeries = runtimeProfile.overviewBasePointsSmallRange
        } else if hours <= 24 {
            basePerSeries = runtimeProfile.overviewBasePointsDayRange
        } else if hours <= 168 {
            basePerSeries = runtimeProfile.overviewBasePointsWeekRange
        } else {
            basePerSeries = runtimeProfile.overviewBasePointsLongRange
        }
        return min(runtimeProfile.overviewTotalPointCeiling, max(basePerSeries, basePerSeries * max(seriesCount, 1)))
    }

    private func defaultChartPointBudget(hours: Double) -> Int {
        if hours <= 4 { return 1_000 }
        if hours <= 24 { return 1_200 }
        if hours <= 168 { return 1_400 }
        return 1_600
    }

    func checkForUpdatesIfNeeded() async {
        // Online update checks are intentionally disabled during the foundation milestone.
    }

    func checkForUpdates(isAutomatic: Bool = false) async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        lastUpdateCheckAt = Date().timeIntervalSince1970
        updateURL = nil
        if !isAutomatic {
            updateStatus = language == .english
                ? "Online update checks are not enabled in this milestone."
                : "当前里程碑未启用在线更新检查。"
        }
    }

    func openUpdatePage() {
        guard let updateURL else { return }
        NSWorkspace.shared.open(updateURL)
    }

    private func scheduleMonitoringLoop() {
        measurementLoopTask?.cancel()
        measurementLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isRunning && !Task.isCancelled {
                let startedAt = Date()
                await self.runMeasurement()
                guard self.isRunning && !Task.isCancelled else { break }

                let interval = max(0.001, TimeInterval(self.measurementIntervalMs) / 1000.0)
                let elapsed = Date().timeIntervalSince(startedAt)
                let sleepSeconds = max(0, interval - elapsed)

                if sleepSeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                }
            }
        }
    }

    private func append(_ newRecords: [MeasurementRecord]) {
        guard !newRecords.isEmpty else { return }
        records = recordIndex.appending(
            newRecords,
            to: records,
            retentionDays: runtimePlan.retentionDays
        )
        invalidateRecordDerivedState()
    }

    private func invalidateRecordDerivedState() {
        statsCache.removeAll(keepingCapacity: true)
        chartCache.removeAll(keepingCapacity: true)
        recordsRevision += 1
    }

    private func normalizedAudioPathKey(_ audioPaths: [String]?) -> [String]? {
        guard let audioPaths, !audioPaths.isEmpty else { return nil }
        return Array(Set(audioPaths)).sorted()
    }

    private func currentMinuteBucket() -> Int {
        Int(Date().timeIntervalSince1970 / 60)
    }

    private func stopMonitoringAfterMeasurementSetupFailure() {
        isRunning = false
        measurementLoopTask?.cancel()
        measurementLoopTask = nil
    }

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { startIndex in
            Array(self[startIndex ..< Swift.min(startIndex + size, count)])
        }
    }
}

private extension View {
    @ViewBuilder
    func compatibleTint(_ color: Color) -> some View {
        if #available(macOS 13.0, *) {
            tint(color)
        } else {
            accentColor(color)
        }
    }

    @ViewBuilder
    func hideAutomaticWindowToolbar() -> some View {
        if #available(macOS 13.0, *) {
            toolbar(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }

    @ViewBuilder
    func integratedWindowTitlebar(_ enabled: Bool) -> some View {
        if enabled, #available(macOS 11.0, *) {
            ignoresSafeArea(.container, edges: .top)
        } else {
            self
        }
    }
}

@available(macOS 12.0, *)
struct ModernContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedHours: Double = 24
    @State private var selectedSidebarPage: String = "overview"
    @State private var navigationDirection: PageNavigationDirection = .downward
    @State private var isSidebarVisible = true

    private var versionedMotionProfile: VersionedMotionProfile {
        VersionedMotionProfile(runtimeProfile: model.runtimeProfile, intensity: model.motionIntensity)
    }

    private var interfaceAnimation: Animation? {
        reduceMotion || model.motionIntensity == .none ? nil : versionedMotionProfile.pageSwitchAnimation
    }

    private var pageTransition: AnyTransition {
        navigationDirection.transition(reduceMotion: reduceMotion, intensity: model.motionIntensity)
    }

    private var sidebarPageOrder: [String] {
        ["settings", "overview", "history", "devices", "labs"] + model.monitoredAudioPathNames.map { "audioPath:\($0)" }
    }

    private var controlButtonTitles: [String] {
        [
            model.t("开始监控"),
            model.t("停止监控"),
            model.t("立即探测"),
            model.t("刷新代理列表"),
            model.t("检查更新"),
            model.t("删除历史数据")
        ]
    }

    private var controlButtonWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widestText = controlButtonTitles
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        return widestText + 4
    }

    private var sidebarColumnWidth: CGFloat { 238 }
    private var titlebarContentHeight: CGFloat { 52 }
    private var collapsedTitleLeadingSpacer: CGFloat { 112 }
    private var usesIntegratedTitlebar: Bool { model.runtimeProfile.osFamily == .macOS15OrNewer }
    private var allowsSidebarCollapse: Bool { model.runtimePlan.allowsSidebarCollapse }
    private var usesLegacy15CompatVisuals: Bool {
        model.runtimeProfile.osFamily == .macOS12
    }

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible || !allowsSidebarCollapse {
                sidebarShell
                    .frame(width: sidebarColumnWidth)
                    .transition(allowsSidebarCollapse ? .move(edge: .leading).combined(with: .opacity) : .identity)

                Divider()
            }

            detailShell
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .integratedWindowTitlebar(usesIntegratedTitlebar)
        .frame(minWidth: 1010, minHeight: 760)
        .compatibleTint(model.accentColor)
        .background(legacyCompatWindowBackground)
        .background(MacOS12StatusBarBridge(model: model).frame(width: 0, height: 0))
        .environment(\.locale, model.locale)
        .animation(interfaceAnimation, value: selectedSidebarPage)
        .animation(interfaceAnimation, value: model.languageCode)
        .animation(interfaceAnimation, value: model.accentColorID)
        .animation(interfaceAnimation, value: model.motionIntensityID)
        .versionedStartupMotion(profile: versionedMotionProfile)
    }

    private var sidebarShell: some View {
        VStack(spacing: 0) {
            if usesIntegratedTitlebar {
                HStack(spacing: 10) {
                    Spacer()
                    if allowsSidebarCollapse {
                        sidebarToggleButton
                    }
                    Text(model.t("节点监控"))
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                }
                .frame(height: titlebarContentHeight)
                .background(sidebarBackground)

                Divider()
            }

            sidebarContent
        }
        .background(sidebarBackground)
    }

    private var detailShell: some View {
        VStack(spacing: 0) {
            if usesIntegratedTitlebar {
                HStack {
                    if !isSidebarVisible, allowsSidebarCollapse {
                        Color.clear
                            .frame(width: collapsedTitleLeadingSpacer)
                        sidebarToggleButton
                        Text(model.t("节点监控"))
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                    } else {
                        Spacer()
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: titlebarContentHeight)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.96))

                Divider()
            }

            detailContent
        }
    }

    private var sidebarBackground: Color {
        usesLegacy15CompatVisuals
            ? Color(NSColor.windowBackgroundColor).opacity(0.82)
            : Color(NSColor.controlBackgroundColor).opacity(0.92)
    }

    private var legacyCompatWindowBackground: some View {
        Group {
            if usesLegacy15CompatVisuals {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(NSColor.windowBackgroundColor).opacity(0.98),
                        Color(NSColor.controlBackgroundColor).opacity(0.88)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                Color.clear
            }
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(interfaceAnimation) {
                isSidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSidebarVisible ? model.t("隐藏侧栏") : model.t("显示侧栏"))
    }

    private var sidebarContent: some View {
        List {
            Section(model.t("Language")) {
                Picker("", selection: $model.languageCode) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Section(model.t("动态效果")) {
                Picker("", selection: $model.motionIntensityID) {
                    Text(model.t("增强")).tag(MotionIntensity.enhanced.rawValue)
                    Text(model.t("减弱")).tag(MotionIntensity.reduced.rawValue)
                    Text(model.t("无动画")).tag(MotionIntensity.none.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Section(model.t("主要颜色")) {
                AccentColorPicker(model: model)
            }

            Section(model.t("设置")) {
                Button {
                    selectPage("settings")
                } label: {
                    HStack {
                        Label(model.t("设置"), systemImage: "slider.horizontal.3")
                        Spacer()
                        if selectedSidebarPage == "settings" {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(Legacy15SidebarButtonStyle(isSelected: selectedSidebarPage == "settings", accentColor: model.accentColor))
            }

            Section(model.t("控制")) {
                controlButton(model.isRunning ? model.t("停止监控") : model.t("开始监控"), isProminent: true) {
                    model.isRunning ? model.stopMonitoring() : model.startMonitoring()
                }

                controlButton(model.t("立即探测")) {
                    Task { await model.runMeasurement() }
                }
                .disabled(model.isMeasuring)

                controlButton(model.t("刷新代理列表")) {
                    Task { await model.refreshAudioPathCatalog() }
                }

                controlButton(model.t("检查更新")) {
                    Task { await model.checkForUpdates() }
                }
                .disabled(model.isCheckingForUpdates)

                controlButton(model.t("删除历史数据"), role: .destructive) {
                    model.clearHistory()
                }
            }

            Section(model.t("状态")) {
                SidebarStatusRow(title: model.t("当前节点")) {
                    Text(model.resolvedAudioPathName)
                }
                SidebarStatusRow(title: model.t("监控节点数")) {
                    Text("\(model.monitoredAudioPathNames.count)")
                        .monospacedDigit()
                }
                SidebarStatusRow(title: model.t("监控状态")) {
                    Text(model.monitoringStatusText)
                }
                if let error = model.latestError, !error.isEmpty {
                    Text(model.displayError(error))
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                if let updateStatus = model.updateStatus, !updateStatus.isEmpty {
                    Text(updateStatus)
                        .foregroundStyle(model.updateURL == nil ? .secondary : model.accentColor)
                        .font(.footnote)
                    if model.updateURL != nil {
                        Button(model.t("打开下载页")) {
                            model.openUpdatePage()
                        }
                        .buttonStyle(LightweightPressButtonStyle())
                    }
                }
            }

            Section(model.t("Overview")) {
                Button {
                    selectPage("overview")
                } label: {
                    HStack {
                        Label(model.t("Overview"), systemImage: "rectangle.stack")
                        Spacer()
                        if selectedSidebarPage == "overview" {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(Legacy15SidebarButtonStyle(isSelected: selectedSidebarPage == "overview", accentColor: model.accentColor))

                Button {
                    selectPage("history")
                } label: {
                    HStack {
                        Label("History", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        if selectedSidebarPage == "history" {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(Legacy15SidebarButtonStyle(isSelected: selectedSidebarPage == "history", accentColor: model.accentColor))

                Button { selectPage("devices") } label: {
                    HStack { Label("Devices", systemImage: "waveform.path"); Spacer(); if selectedSidebarPage == "devices" { Image(systemName: "checkmark") } }
                }
                .buttonStyle(Legacy15SidebarButtonStyle(isSelected: selectedSidebarPage == "devices", accentColor: model.accentColor))

                Button { selectPage("labs") } label: {
                    HStack { Label("Labs", systemImage: "flask"); Spacer(); if selectedSidebarPage == "labs" { Image(systemName: "checkmark") } }
                }
                .buttonStyle(Legacy15SidebarButtonStyle(isSelected: selectedSidebarPage == "labs", accentColor: model.accentColor))
            }

            Section(model.t("节点分页")) {
                ForEach(model.monitoredAudioPathNames, id: \.self) { audioPath in
                    Button {
                        selectPage("audioPath:\(audioPath)")
                    } label: {
                        HStack {
                            Text(audioPath)
                                .lineLimit(1)
                            Spacer()
                            if selectedSidebarPage == "audioPath:\(audioPath)" {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(Legacy15SidebarButtonStyle(isSelected: selectedSidebarPage == "audioPath:\(audioPath)", accentColor: model.accentColor))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var detailContent: some View {
        GeometryReader { geometry in
            if selectedSidebarPage == "settings" {
                SettingsPage(availableHeight: geometry.size.height)
                    .environmentObject(model)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(selectedSidebarPage)
                    .transition(pageTransition)
                    .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                    .coordinateSpace(name: "detailScroll")
            } else if selectedSidebarPage == "history" {
                if #available(macOS 13.0, *) {
                    MeasurementHistoryView(
                        viewModel: model.historyViewModel,
                        accentColor: model.accentColor,
                        motionProfile: versionedMotionProfile
                    )
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(selectedSidebarPage)
                    .transition(pageTransition)
                    .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
            } else if selectedSidebarPage == "devices" {
                DeviceProfilerPage()
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(selectedSidebarPage)
                    .transition(pageTransition)
                    .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                }
            } else if selectedSidebarPage == "labs" {
                MeasurementLabsPage()
                    .environmentObject(model)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(selectedSidebarPage)
                    .transition(pageTransition)
                    .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
            } else if selectedSidebarPage.hasPrefix("audioPath:") {
                let audioPathName = String(selectedSidebarPage.dropFirst("audioPath:".count))
                AudioPathPageView(
                    audioPathName: audioPathName,
                    selectedHours: $selectedHours,
                    availableHeight: geometry.size.height,
                    navigationDirection: navigationDirection
                )
                .environmentObject(model)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(selectedSidebarPage)
                .transition(pageTransition)
                .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                .coordinateSpace(name: "detailScroll")
            } else {
                ScrollViewReader { scrollAudioPath in
                    ScrollView {
                        Color.clear
                            .frame(height: 0)
                            .id("detailTop")

                        OverviewPage()
                            .environmentObject(model)
                            .padding(20)
                            .id(selectedSidebarPage)
                            .transition(pageTransition)
                    }
                    .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                    .coordinateSpace(name: "detailScroll")
                    .onChange(of: selectedSidebarPage) { _ in
                        withAnimation(interfaceAnimation) {
                            scrollAudioPath.scrollTo("detailTop", anchor: .top)
                        }
                    }
                }
            }
        }
    }

    private func selectPage(_ page: String) {
        guard page != selectedSidebarPage else { return }
        let currentIndex = sidebarPageOrder.firstIndex(of: selectedSidebarPage) ?? 0
        let nextIndex = sidebarPageOrder.firstIndex(of: page) ?? currentIndex
        navigationDirection = nextIndex >= currentIndex ? .downward : .upward
        withAnimation(interfaceAnimation) {
            selectedSidebarPage = page
        }
    }

    private func controlButton(_ title: String, role: ButtonRole? = nil, isProminent: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if isProminent {
                Button(role: role, action: action) {
                    Text(title)
                        .frame(width: controlButtonWidth)
                }
                .buttonStyle(Legacy15ControlButtonStyle(isProminent: true, accentColor: model.accentColor))
            } else {
                Button(role: role, action: action) {
                    Text(title)
                        .frame(width: controlButtonWidth)
                }
                .buttonStyle(Legacy15ControlButtonStyle(isProminent: false, accentColor: model.accentColor))
            }
        }
        .compatibleTint(model.accentColor)
    }
}

@available(macOS 13.0, *)
struct NativeModernContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedHours: Double = 24
    @State private var selectedSidebarPage: String = "overview"
    @State private var navigationDirection: PageNavigationDirection = .downward

    private var versionedMotionProfile: VersionedMotionProfile {
        VersionedMotionProfile(runtimeProfile: model.runtimeProfile, intensity: model.motionIntensity)
    }

    private var interfaceAnimation: Animation? {
        reduceMotion || model.motionIntensity == .none ? nil : versionedMotionProfile.pageSwitchAnimation
    }

    private var pageTransition: AnyTransition {
        navigationDirection.transition(reduceMotion: reduceMotion, intensity: model.motionIntensity)
    }

    private var sidebarPageOrder: [String] {
        ["settings", "overview", "history", "devices", "labs"] + model.monitoredAudioPathNames.map { "audioPath:\($0)" }
    }

    private var controlButtonTitles: [String] {
        [
            model.t("开始监控"),
            model.t("停止监控"),
            model.t("立即探测"),
            model.t("刷新代理列表"),
            model.t("检查更新"),
            model.t("删除历史数据")
        ]
    }

    private var controlButtonWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widestText = controlButtonTitles
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        return widestText + 24
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section(model.t("Language")) {
                    Picker("", selection: $model.languageCode) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Section(model.t("动态效果")) {
                    Picker("", selection: $model.motionIntensityID) {
                        Text(model.t("增强")).tag(MotionIntensity.enhanced.rawValue)
                        Text(model.t("减弱")).tag(MotionIntensity.reduced.rawValue)
                        Text(model.t("无动画")).tag(MotionIntensity.none.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Section(model.t("主要颜色")) {
                    AccentColorPicker(model: model)
                }

                Section(model.t("设置")) {
                    Button {
                        selectPage("settings")
                    } label: {
                        HStack {
                            Label(model.t("设置"), systemImage: "slider.horizontal.3")
                            Spacer()
                            if selectedSidebarPage == "settings" {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(VersionedPagePressButtonStyle(isSelected: selectedSidebarPage == "settings", accentColor: model.accentColor, profile: versionedMotionProfile))
                }

                Section(model.t("控制")) {
                    controlButton(model.isRunning ? model.t("停止监控") : model.t("开始监控"), isProminent: true) {
                        model.isRunning ? model.stopMonitoring() : model.startMonitoring()
                    }

                    controlButton(model.t("立即探测")) {
                        Task { await model.runMeasurement() }
                    }
                    .disabled(model.isMeasuring)

                    controlButton(model.t("刷新代理列表")) {
                        Task { await model.refreshAudioPathCatalog() }
                    }

                    controlButton(model.t("检查更新")) {
                        Task { await model.checkForUpdates() }
                    }
                    .disabled(model.isCheckingForUpdates)

                    controlButton(model.t("删除历史数据"), role: .destructive) {
                        model.clearHistory()
                    }
                }

                Section(model.t("状态")) {
                    LabeledContent(model.t("当前节点")) {
                        Text(model.resolvedAudioPathName)
                    }
                    LabeledContent(model.t("监控节点数")) {
                        Text("\(model.monitoredAudioPathNames.count)")
                            .monospacedDigit()
                    }
                    LabeledContent(model.t("监控状态")) {
                        Text(model.monitoringStatusText)
                    }
                    if let error = model.latestError, !error.isEmpty {
                        Text(model.displayError(error))
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                    if let updateStatus = model.updateStatus, !updateStatus.isEmpty {
                        Text(updateStatus)
                            .foregroundStyle(model.updateURL == nil ? .secondary : model.accentColor)
                            .font(.footnote)
                        if model.updateURL != nil {
                            Button(model.t("打开下载页")) {
                                model.openUpdatePage()
                            }
                            .buttonStyle(LightweightPressButtonStyle())
                        }
                    }
                }

                Section(model.t("Overview")) {
                    Button {
                        selectPage("overview")
                    } label: {
                        HStack {
                            Label(model.t("Overview"), systemImage: "rectangle.stack")
                            Spacer()
                            if selectedSidebarPage == "overview" {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(VersionedPagePressButtonStyle(isSelected: selectedSidebarPage == "overview", accentColor: model.accentColor, profile: versionedMotionProfile))

                    Button {
                        selectPage("history")
                    } label: {
                        HStack {
                            Label("History", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            if selectedSidebarPage == "history" {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                .buttonStyle(VersionedPagePressButtonStyle(isSelected: selectedSidebarPage == "history", accentColor: model.accentColor, profile: versionedMotionProfile))

                Button { selectPage("devices") } label: {
                    HStack { Label("Devices", systemImage: "waveform.path"); Spacer(); if selectedSidebarPage == "devices" { Image(systemName: "checkmark") } }
                }
                .buttonStyle(VersionedPagePressButtonStyle(isSelected: selectedSidebarPage == "devices", accentColor: model.accentColor, profile: versionedMotionProfile))

                Button { selectPage("labs") } label: {
                    HStack { Label("Labs", systemImage: "flask"); Spacer(); if selectedSidebarPage == "labs" { Image(systemName: "checkmark") } }
                }
                .buttonStyle(VersionedPagePressButtonStyle(isSelected: selectedSidebarPage == "labs", accentColor: model.accentColor, profile: versionedMotionProfile))
                }

                Section(model.t("节点分页")) {
                    ForEach(model.monitoredAudioPathNames, id: \.self) { audioPath in
                        Button {
                            selectPage("audioPath:\(audioPath)")
                        } label: {
                            HStack {
                                Text(audioPath)
                                    .lineLimit(1)
                                Spacer()
                                if selectedSidebarPage == "audioPath:\(audioPath)" {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(VersionedPagePressButtonStyle(isSelected: selectedSidebarPage == "audioPath:\(audioPath)", accentColor: model.accentColor, profile: versionedMotionProfile))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("AudioLink Lab")
            .navigationSplitViewColumnWidth(min: 248, ideal: 272, max: 330)
        } detail: {
            GeometryReader { geometry in
                if selectedSidebarPage == "settings" {
                    SettingsPage(availableHeight: geometry.size.height)
                        .environmentObject(model)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id(selectedSidebarPage)
                        .transition(pageTransition)
                        .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                        .coordinateSpace(name: "detailScroll")
                } else if selectedSidebarPage == "history" {
                    MeasurementHistoryView(
                        viewModel: model.historyViewModel,
                        accentColor: model.accentColor,
                        motionProfile: versionedMotionProfile
                    )
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(selectedSidebarPage)
                    .transition(pageTransition)
                    .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                } else if selectedSidebarPage == "devices" {
                    DeviceProfilerPage()
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id(selectedSidebarPage)
                        .transition(pageTransition)
                        .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                } else if selectedSidebarPage == "labs" {
                    MeasurementLabsPage()
                        .environmentObject(model)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id(selectedSidebarPage)
                        .transition(pageTransition)
                        .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                } else if selectedSidebarPage.hasPrefix("audioPath:") {
                    let audioPathName = String(selectedSidebarPage.dropFirst("audioPath:".count))
                    AudioPathPageView(
                        audioPathName: audioPathName,
                        selectedHours: $selectedHours,
                        availableHeight: geometry.size.height,
                        navigationDirection: navigationDirection
                    )
                    .environmentObject(model)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(selectedSidebarPage)
                    .transition(pageTransition)
                    .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                    .coordinateSpace(name: "detailScroll")
                } else {
                    ScrollViewReader { scrollAudioPath in
                        ScrollView {
                            Color.clear
                                .frame(height: 0)
                                .id("detailTop")

                            OverviewPage()
                                .environmentObject(model)
                                .padding(20)
                                .id(selectedSidebarPage)
                                .transition(pageTransition)
                        }
                        .versionedPageSwitchMotion(profile: versionedMotionProfile, pageID: selectedSidebarPage, direction: navigationDirection)
                        .coordinateSpace(name: "detailScroll")
                        .onChange(of: selectedSidebarPage) { _ in
                            withAnimation(interfaceAnimation) {
                                scrollAudioPath.scrollTo("detailTop", anchor: .top)
                            }
                        }
                    }
                }
            }
            .navigationTitle(model.t("节点监控"))
        }
        .frame(
            minWidth: AudioLinkLayoutMetrics.minimumWindowWidth,
            minHeight: AudioLinkLayoutMetrics.minimumWindowHeight
        )
        .tint(model.accentColor)
        .environment(\.locale, model.locale)
        .animation(interfaceAnimation, value: selectedSidebarPage)
        .animation(interfaceAnimation, value: model.languageCode)
        .animation(interfaceAnimation, value: model.accentColorID)
        .animation(interfaceAnimation, value: model.motionIntensityID)
        .versionedStartupMotion(profile: versionedMotionProfile)
    }

    private func selectPage(_ page: String) {
        guard page != selectedSidebarPage else { return }
        let currentIndex = sidebarPageOrder.firstIndex(of: selectedSidebarPage) ?? 0
        let nextIndex = sidebarPageOrder.firstIndex(of: page) ?? currentIndex
        navigationDirection = nextIndex >= currentIndex ? .downward : .upward
        withAnimation(interfaceAnimation) {
            selectedSidebarPage = page
        }
    }

    private func controlButton(_ title: String, role: ButtonRole? = nil, isProminent: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if isProminent {
                Button(role: role, action: action) {
                    Text(title)
                        .frame(width: controlButtonWidth)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(role: role, action: action) {
                    Text(title)
                        .frame(width: controlButtonWidth)
                }
                .buttonStyle(.bordered)
            }
        }
        .tint(model.accentColor)
    }
}

@available(macOS 12.0, *)
struct AccentColorPicker: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 16), spacing: 7), count: 8)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(AccentColorOption.all) { option in
                Button {
                    withAnimation(reduceMotion ? nil : MotionTokens.color) {
                        model.accentColorID = option.id
                    }
                } label: {
                    ZStack {
                        Capsule(style: .continuous)
                            .fill(option.color)
                        .frame(height: 14)
                            .overlay {
                                if model.accentColorID == option.id {
                                    Capsule(style: .continuous)
                                        .strokeBorder(.primary.opacity(0.9), lineWidth: 1.5)
                                        .overlay {
                                            Capsule(style: .continuous)
                                                .strokeBorder(.white.opacity(0.9), lineWidth: 0.8)
                                        }
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                    .accessibilityLabel(option.name(for: model.language))
                }
                .buttonStyle(LightweightPressButtonStyle())
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(macOS 12.0, *)
struct SidebarStatusRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            content
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

@available(macOS 12.0, *)
struct OverviewPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measurementMode: MeasurementMode = .files
    @State private var measurementNavigationDirection: PageNavigationDirection = .downward

    private enum MeasurementMode: String, CaseIterable, Identifiable {
        case files = "Files"
        case realtime = "Real-time"
        case repeated = "Repeated"
        case calibration = "Calibration"
        case stability = "Stability"
        var id: String { rawValue }
    }

    private var versionedMotionProfile: VersionedMotionProfile {
        VersionedMotionProfile(runtimeProfile: model.runtimeProfile, intensity: model.motionIntensity)
    }

    private var interfaceAnimation: Animation? {
        reduceMotion || model.motionIntensity == .none ? nil : versionedMotionProfile.pageSwitchAnimation
    }

    private var measurementModeSelection: Binding<MeasurementMode> {
        Binding(
            get: { measurementMode },
            set: { nextMode in
                guard nextMode != measurementMode else { return }
                let modes = MeasurementMode.allCases
                let currentIndex = modes.firstIndex(of: measurementMode) ?? 0
                let nextIndex = modes.firstIndex(of: nextMode) ?? currentIndex
                measurementNavigationDirection = nextIndex >= currentIndex ? .downward : .upward
                withAnimation(interfaceAnimation) {
                    measurementMode = nextMode
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Measurement mode", selection: measurementModeSelection) {
                Label("Analyze Files", systemImage: "waveform.badge.magnifyingglass")
                    .tag(MeasurementMode.files)
                Label("Real-time", systemImage: "speaker.wave.2.fill")
                    .tag(MeasurementMode.realtime)
                Label("Repeated", systemImage: "repeat.circle.fill")
                    .tag(MeasurementMode.repeated)
                Label("Calibration", systemImage: "tuningfork")
                    .tag(MeasurementMode.calibration)
                Label("Stability", systemImage: "chart.xyaxis.line")
                    .tag(MeasurementMode.stability)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 560)
            .versionedComponentAppear(
                profile: versionedMotionProfile,
                pageID: "measurement-mode-picker",
                direction: .downward
            )

            measurementContent
                .id(measurementMode.id)
                .transition(
                    measurementNavigationDirection.transition(
                        reduceMotion: reduceMotion,
                        intensity: model.motionIntensity
                    )
                )
                .versionedPageSwitchMotion(
                    profile: versionedMotionProfile,
                    pageID: measurementMode.id,
                    direction: measurementNavigationDirection
                )
        }
        .frame(maxWidth: AudioLinkLayoutMetrics.maximumMeasurementContentWidth, alignment: .leading)
    }

    @ViewBuilder
    private var measurementContent: some View {
        Group {
            switch measurementMode {
            case .files:
                NewMeasurementView(
                    viewModel: model.newMeasurementViewModel,
                    accentColor: model.accentColor,
                    motionProfile: versionedMotionProfile
                )
            case .realtime:
                RealtimeMeasurementView(
                    viewModel: model.realtimeMeasurementViewModel,
                    accentColor: model.accentColor,
                    motionProfile: versionedMotionProfile
                )
            case .repeated:
                RepeatedMeasurementView(
                    viewModel: model.repeatedMeasurementViewModel,
                    accentColor: model.accentColor,
                    motionProfile: versionedMotionProfile
                )
            case .calibration:
                CalibrationView(
                    viewModel: model.calibrationViewModel,
                    accentColor: model.accentColor,
                    motionProfile: versionedMotionProfile
                )
            case .stability:
                LongTermStabilityView(
                    viewModel: model.longTermStabilityViewModel,
                    accentColor: model.accentColor,
                    motionProfile: versionedMotionProfile
                )
            }
        }
    }
}

@available(macOS 12.0, *)
struct AudioPathPageView: View {
    @EnvironmentObject private var model: AppModel
    let audioPathName: String
    @Binding var selectedHours: Double
    var availableHeight: CGFloat? = nil
    let navigationDirection: PageNavigationDirection
    @State private var latestRecordsTableHeight: CGFloat = 180

    private var versionedMotionProfile: VersionedMotionProfile {
        VersionedMotionProfile(runtimeProfile: model.runtimeProfile, intensity: model.motionIntensity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerCards
                .versionedComponentAppear(profile: versionedMotionProfile, pageID: "audioPath:\(audioPathName)", direction: navigationDirection)
            chartSection
                .versionedComponentAppear(profile: versionedMotionProfile, pageID: "audioPath:\(audioPathName)", direction: navigationDirection, isChart: true)
            latestRecordsSection
                .versionedComponentAppear(profile: versionedMotionProfile, pageID: "audioPath:\(audioPathName)", direction: navigationDirection)
        }
    }

    private var headerCards: some View {
        let stats = model.stats(for: audioPathName)
        return HStack(spacing: 12) {
            StatCard(title: model.t("上次延迟"), value: stats.lastLatency.map { "\($0) ms" } ?? "--", compact: true)
            StatCard(title: model.t("24h 平均延迟"), value: stats.avgLatency24h.map { String(format: "%.1f ms", $0) } ?? "--", compact: true)
            StatCard(title: model.t("24h 最高延迟"), value: stats.clockDriftPPM.map { String(format: "%.2f ppm", $0) } ?? "--", compact: true)
            StatCard(title: model.t("24h 丢包率"), value: stats.jitterMilliseconds.map { String(format: "%.2f ms", $0) } ?? "--", compact: true)
            StatCard(title: model.t("24h 可用率"), value: stats.correlationConfidence.map { String(format: "%.1f%%", $0 * 100) } ?? "--", compact: true)
        }
    }

    private var chartSection: some View {
        let records = model.chartData(
            hours: selectedHours,
            audioPath: audioPathName,
            maxTotalPoints: model.audioPathChartPointBudget(hours: selectedHours),
            minimumPointsPerSeries: model.audioPathChartPointBudget(hours: selectedHours)
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.t("延迟曲线")) · \(audioPathName)")
                    .font(.title3.bold())
                Spacer()
                TimeRangePicker(selectedHours: $selectedHours, model: model)
            }

            LatencyChart(
                records: records,
                color: model.accentColor,
                maxRenderedPoints: model.audioPathChartPointBudget(hours: selectedHours)
            )
                .frame(height: 320)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .interactivePanel(accentColor: model.accentColor)
                .overlay {
                    if records.isEmpty {
                        EmptyChartOverlay(model: model)
                    }
                }
        }
    }

    private var latestRecordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let pageRecords = model.recentRecords(for: audioPathName, limit: 100)

            HStack {
                Text(model.t("最近记录"))
                    .font(.title3.bold())
                Spacer()
                Button(model.t("清空历史")) {
                    model.clearHistory(for: audioPathName)
                }
                .buttonStyle(.bordered)
            }

            RecentRecordsTable(records: pageRecords, model: model)
            .frame(height: latestRecordsTableHeight)
            .background {
                GeometryReader { geometry in
                    let minY = geometry.frame(in: .named("detailScroll")).minY
                    Color.clear
                        .onAppear {
                            updateLatestRecordsTableHeight(from: minY)
                        }
                        .onChange(of: minY) { nextMinY in
                            updateLatestRecordsTableHeight(from: nextMinY)
                        }
                        .onChange(of: availableHeight ?? 0) { _ in
                            updateLatestRecordsTableHeight(from: minY)
                        }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.22), lineWidth: 1)
            }
            .interactivePanel(cornerRadius: 14, accentColor: model.accentColor)
        }
    }

    private func updateLatestRecordsTableHeight(from minY: CGFloat) {
        guard let availableHeight else { return }
        let bottomPadding: CGFloat = 28
        let nextHeight = max(120, availableHeight - minY - bottomPadding)
        guard abs(latestRecordsTableHeight - nextHeight) > 0.5 else { return }
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                latestRecordsTableHeight = nextHeight
            }
        }
    }
}

@available(macOS 12.0, *)
struct RecentRecordsTable: View {
    let records: [MeasurementRecord]
    let model: AppModel

    private let horizontalPadding: CGFloat = 14
    private let columnSpacing: CGFloat = 12
    private let timeWidth: CGFloat = 172
    private let nodeWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            tableHeader
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 9)
                .background(Color.secondary.opacity(0.08))

            Divider()

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(records) { record in
                        recordRow(record)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: columnSpacing) {
            headerText(model.t("时间"))
                .frame(width: timeWidth, alignment: .leading)
            headerText(model.t("节点"))
                .frame(width: nodeWidth, alignment: .leading)
            headerText(model.t("结果"))
                .frame(maxWidth: .infinity, alignment: .leading)
            headerText(model.t("延迟"))
                .frame(maxWidth: .infinity, alignment: .leading)
            headerText(model.t("说明"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recordRow(_ record: MeasurementRecord) -> some View {
        HStack(spacing: columnSpacing) {
            Text(record.timestamp, format: .dateTime.month().day().hour().minute().second())
                .frame(width: timeWidth, alignment: .leading)
            Text(record.audioPathName)
                .frame(width: nodeWidth, alignment: .leading)
            Text(record.success ? model.t("成功") : model.t("失败"))
                .foregroundStyle(record.success ? .green : .red)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(record.latencyMs.map { "\($0) ms" } ?? "--")
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(record.errorDescription.map(model.displayError) ?? "")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func headerText(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

@available(macOS 12.0, *)
struct AudioPathStatsOverviewRow: View {
    @EnvironmentObject private var model: AppModel
    let audioPathName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(audioPathName)
                .font(.title3.bold())
            statsCards
        }
    }

    private var statsCards: some View {
        let stats = model.stats(for: audioPathName)
        return HStack(spacing: 12) {
            StatCard(title: model.t("上次延迟"), value: stats.lastLatency.map { "\($0) ms" } ?? "--", compact: true)
            StatCard(title: model.t("24h 平均延迟"), value: stats.avgLatency24h.map { String(format: "%.1f ms", $0) } ?? "--", compact: true)
            StatCard(title: model.t("24h 最高延迟"), value: stats.clockDriftPPM.map { String(format: "%.2f ppm", $0) } ?? "--", compact: true)
            StatCard(title: model.t("24h 丢包率"), value: stats.jitterMilliseconds.map { String(format: "%.2f ms", $0) } ?? "--", compact: true)
            StatCard(title: model.t("24h 可用率"), value: stats.correlationConfidence.map { String(format: "%.1f%%", $0 * 100) } ?? "--", compact: true)
        }
    }
}

@available(macOS 12.0, *)
struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    var availableHeight: CGFloat? = nil

    private var versionedMotionProfile: VersionedMotionProfile {
        VersionedMotionProfile(runtimeProfile: model.runtimeProfile, intensity: model.motionIntensity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t("设置"))
                .font(.title2.bold())
                .versionedComponentAppear(profile: versionedMotionProfile, pageID: "settings", direction: .unchanged)
            SettingsPanel(model: model, availableHeight: availableHeight)
                .versionedComponentAppear(profile: versionedMotionProfile, pageID: "settings", direction: .unchanged)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@available(macOS 12.0, *)
struct TimeRangePicker: View {
    @Binding var selectedHours: Double
    @ObservedObject var model: AppModel

    var body: some View {
        Picker(model.t("时间范围"), selection: $selectedHours) {
            Text("1h").tag(1.0)
            Text("4h").tag(4.0)
            Text("12h").tag(12.0)
            Text("24h").tag(24.0)
            Text("7d").tag(168.0)
            Text("1m").tag(720.0)
            Text("3m").tag(2160.0)
        }
        .pickerStyle(.segmented)
        .frame(width: 460)
    }
}

@available(macOS 12.0, *)
struct EmptyChartOverlay: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.largeTitle)
            Text(model.t("还没有延迟数据"))
                .font(.headline)
            Text(model.t("点击“开始监控”或“立即探测”后，这里会开始画曲线。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
    }
}

@available(macOS 12.0, *)
struct SettingsPanel: View {
    @ObservedObject var model: AppModel
    var availableHeight: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedHistoryAudioPathName = ""

    private var settingsAnimation: Animation? {
        reduceMotion ? nil : MotionTokens.soft
    }

    private var manualAudioPathChoices: [String] {
        Array(Set(model.availableAudioPaths + model.selectedManualAudioPathNames)).sorted()
    }

    private var historyAudioPathChoices: [String] {
        uniqueChoices(model.monitoredAudioPathNames + model.selectedManualAudioPathNames + model.availableAudioPaths)
    }

    private var activeHistoryAudioPathName: String {
        if !selectedHistoryAudioPathName.isEmpty, historyAudioPathChoices.contains(selectedHistoryAudioPathName) {
            return selectedHistoryAudioPathName
        }
        return historyAudioPathChoices.first ?? ""
    }

    private var inputDeviceNameChoices: [String] {
        uniqueChoices([
            model.inputDeviceName,
            "System Default Input"
        ])
    }

    private var outputDeviceChoices: [String] {
        uniqueChoices([
            model.outputDeviceName,
            "System Default Output"
        ])
    }

    private var excitationSignalNameChoices: [String] {
        uniqueChoices([
            model.excitationSignalName,
            "Sine Sweep",
            "Impulse",
            "Maximum-Length Sequence"
        ])
    }

    private let measurementIntervalChoices = [5000, 10000, 30000, 60000, 120000]
    private let repetitionCountChoices = [1, 2, 3, 4, 5]

    var body: some View {
        GeometryReader { geometry in
            settingsRows(manualAudioPathListHeight: manualAudioPathListHeight(for: geometry.size.height))
        }
    }

    private func settingsRows(manualAudioPathListHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSection(title: model.t("连接与认证"), index: 0) {
                inputDeviceNameRow
                outputDeviceRow
            }

            settingsSection(title: model.t("监控节点"), index: 1) {
                monitorAllRow
                followGroupRow
                audioPathGroupRow
                manualAudioPathRow(height: manualAudioPathListHeight)
            }

            settingsSection(title: model.t("探测参数"), index: 2) {
                excitationSignalNameRow
                dataPointIntervalRow
                delayTimeoutRow
                repetitionCountRow
            }

            settingsSection(title: model.t("数据库管理"), index: 3) {
                databaseSummaryRow
                databaseActionsRow
            }
        }
        .onChange(of: model.followSystemDefaultDevices) { _ in
            Task { await model.refreshAudioPathCatalog() }
        }
        .onChange(of: model.measureAllAudioPaths) { _ in
            Task { await model.refreshAudioPathCatalog() }
        }
        .onChange(of: model.measurementIntervalMs) { _ in
            model.rescheduleMonitoringIfNeeded()
        }
        .animation(settingsAnimation, value: model.followSystemDefaultDevices)
        .animation(settingsAnimation, value: model.measureAllAudioPaths)
        .animation(settingsAnimation, value: model.measurementIntervalMs)
        .animation(settingsAnimation, value: model.repetitionCount)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func manualAudioPathListHeight(for panelHeight: CGFloat) -> CGFloat {
        let fixedContentHeight: CGFloat = 552
        let bottomPadding: CGFloat = 4
        return max(52, panelHeight - fixedContentHeight - bottomPadding)
    }

    private func settingsSection<Content: View>(title: String, index: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .settingsSolidCard(accentColor: model.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .staggeredGroupAppear(index: index)
    }

    private var inputDeviceNameRow: some View {
        SettingsRow(title: model.t("Input Device")) {
            HStack {
                Picker(model.t("Input Device"), selection: $model.inputDeviceName) {
                    ForEach(inputDeviceNameChoices, id: \.self) { url in
                        Text(url).tag(url)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Button(model.t("刷新代理列表")) {
                    Task { await model.refreshAudioPathCatalog() }
                }
            }
        }
    }

    private var outputDeviceRow: some View {
        SettingsRow(title: model.t("Output Device")) {
            Picker(model.t("Output Device"), selection: $model.outputDeviceName) {
                ForEach(outputDeviceChoices, id: \.self) { device in
                    Text(device).tag(device)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var monitorAllRow: some View {
        SettingsRow(title: "") {
            Toggle(model.t("自动监控代理组所有节点"), isOn: $model.measureAllAudioPaths)
        }
    }

    private var followGroupRow: some View {
        SettingsRow(title: "") {
            Toggle(model.t("跟随代理组当前节点"), isOn: $model.followSystemDefaultDevices)
                .disabled(model.measureAllAudioPaths)
        }
    }

    private var audioPathGroupRow: some View {
        SettingsRow(title: model.t("代理组")) {
            Picker(model.t("代理组"), selection: $model.deviceSetName) {
                ForEach(model.availableDeviceSets, id: \.self) { group in
                    Text(group).tag(group)
                }
            }
            .disabled(!model.followSystemDefaultDevices && !model.measureAllAudioPaths)
        }
    }

    private func manualAudioPathRow(height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.t("手动多选节点"))
                Text(model.t("勾选多个节点后，每轮采样都会分别记录，并在左侧节点分页中逐页查看。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 160, alignment: .leading)

            manualAudioPathSelectionList(height: height)
        }
    }

    private var excitationSignalNameRow: some View {
        SettingsRow(title: model.t("探测目标")) {
            HStack {
                Picker(model.t("探测目标"), selection: $model.excitationSignalName) {
                    ForEach(excitationSignalNameChoices, id: \.self) { url in
                        Text(url).tag(url)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

            }
        }
    }

    private var dataPointIntervalRow: some View {
        SettingsRow(title: model.t("数据点间隔")) {
            HStack {
                Picker(model.t("数据点间隔"), selection: $model.measurementIntervalMs) {
                    ForEach(measurementIntervalChoices, id: \.self) { interval in
                        Text("\(interval)").tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("ms")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var delayTimeoutRow: some View {
        SettingsRow(title: model.t("测速超时")) {
            Stepper(value: $model.captureWindowMs, in: 1000 ... 30000, step: 500) {
                Text("\(model.captureWindowMs) ms")
            }
        }
    }

    private var repetitionCountRow: some View {
        SettingsRow(title: model.t("每点探测次数")) {
            HStack {
                Picker(model.t("每点探测次数"), selection: $model.repetitionCount) {
                    ForEach(repetitionCountChoices, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text(model.t("次，取最小值"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var databaseSummaryRow: some View {
        SettingsRow(title: model.t("数据库")) {
            HStack(spacing: 16) {
                Text(model.databaseSizeText)
                    .monospacedDigit()
                Text("\(model.t("记录数")) \(model.databaseRecordCountText)")
                    .foregroundStyle(.secondary)
                Text("\(model.t("保留策略")) \(model.retentionPolicyText)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var databaseActionsRow: some View {
        SettingsRow(title: model.t("历史管理")) {
            HStack(spacing: 10) {
                Picker(model.t("节点"), selection: Binding(
                    get: { activeHistoryAudioPathName },
                    set: { selectedHistoryAudioPathName = $0 }
                )) {
                    ForEach(historyAudioPathChoices, id: \.self) { audioPath in
                        Text(audioPath).tag(audioPath)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .disabled(historyAudioPathChoices.isEmpty)

                Button(model.t("清理此节点")) {
                    model.clearHistory(for: activeHistoryAudioPathName)
                }
                .disabled(activeHistoryAudioPathName.isEmpty)

                Button(model.t("导出 CSV")) {
                    model.exportHistoryCSV()
                }
                .disabled(model.records.isEmpty)
            }
            if let message = model.databaseStatusMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func manualAudioPathSelectionList(height: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(manualAudioPathChoices, id: \.self) { audioPath in
                    Toggle(
                        audioPath,
                        isOn: Binding(
                            get: { model.selectedManualAudioPathNames.contains(audioPath) },
                            set: { model.setManualAudioPath(audioPath, isSelected: $0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                }

                if manualAudioPathChoices.isEmpty {
                    Text(model.t("点击“刷新代理列表”后选择节点。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: height)
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .disabled(model.followSystemDefaultDevices || model.measureAllAudioPaths)
    }

    private func pasteString(into keyPath: ReferenceWritableKeyPath<AppModel, String>) {
        guard let string = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !string.isEmpty
        else {
            return
        }
        model[keyPath: keyPath] = string
    }

    private func uniqueChoices(_ choices: [String]) -> [String] {
        var seen = Set<String>()
        return choices.compactMap { choice in
            let trimmed = choice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else {
                return nil
            }
            seen.insert(trimmed)
            return trimmed
        }
    }
}

@available(macOS 12.0, *)
struct SettingsRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if title.isEmpty {
                Spacer(minLength: 0)
                    .frame(width: 160)
            } else {
                Text(title)
                    .frame(width: 160, alignment: .leading)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@available(macOS 12.0, *)
struct LatencyChart: View {
    let records: [MeasurementRecord]
    let color: Color
    var maxRenderedPoints: Int = 700

    private func nativePointBudget(width: CGFloat) -> Int {
        let widthBudget = max(220, Int(width * 0.46))
        return min(maxRenderedPoints, widthBudget)
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            GeometryReader { geometry in
                let budget = nativePointBudget(width: geometry.size.width)
                let renderedRecords = ChartDownsampler.reduce(
                    records,
                    maxTotalPoints: budget,
                    minimumPointsPerSeries: budget
                )
                let showsDenseDecorations = renderedRecords.count <= 180

                ModernLatencyChart(
                    records: renderedRecords,
                    color: color,
                    showsDenseBars: showsDenseDecorations,
                    showsArea: showsDenseDecorations
                )
            }
        } else {
            let renderedRecords = ChartDownsampler.reduce(
                records,
                maxTotalPoints: maxRenderedPoints,
                minimumPointsPerSeries: maxRenderedPoints
            )
            PathLatencyChart(
                records: renderedRecords,
                series: [ChartSeriesStyle(audioPathName: nil, color: color)],
                showsBars: renderedRecords.count <= 360,
                showsAxes: true,
                showsArea: true
            )
        }
    }

}

@available(macOS 12.0, *)
struct MenuLatencySparkline: View {
    let records: [MeasurementRecord]
    let color: Color

    var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                ModernMenuLatencySparkline(records: records, color: color)
            } else {
                PathLatencyChart(
                    records: records,
                    series: [ChartSeriesStyle(audioPathName: nil, color: color)],
                    showsBars: records.count <= 160,
                    showsAxes: false,
                    showsArea: true
                )
            }
        }
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }
}

@available(macOS 12.0, *)
struct MultiLatencyChart: View {
    let records: [MeasurementRecord]
    let audioPathNames: [String]

    private func nativePerSeriesBudget(width: CGFloat) -> Int {
        let seriesCount = max(audioPathNames.count, 1)
        let perSeriesWidth = width / CGFloat(seriesCount)
        return max(120, min(320, Int(perSeriesWidth * 1.1)))
    }

    private func color(for audioPathName: String) -> Color {
        let palette = AccentColorOption.all.map(\.color)
        guard let index = audioPathNames.firstIndex(of: audioPathName), !palette.isEmpty else {
            return .purple
        }
        return palette[index % palette.count]
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            GeometryReader { geometry in
                let perSeriesBudget = nativePerSeriesBudget(width: geometry.size.width)
                let renderedRecords = ChartDownsampler.reduce(
                    records,
                    maxTotalPoints: perSeriesBudget * max(audioPathNames.count, 1),
                    minimumPointsPerSeries: perSeriesBudget
                )
                ModernMultiLatencyChart(records: renderedRecords, audioPathNames: audioPathNames)
            }
        } else {
            PathLatencyChart(
                records: records,
                series: audioPathNames.map { ChartSeriesStyle(audioPathName: $0, color: color(for: $0)) },
                showsBars: false,
                showsAxes: true,
                showsArea: false
            )
        }
    }

}

private struct ChartSeriesStyle: Identifiable {
    let id: String
    let audioPathName: String?
    let color: Color

    init(audioPathName: String?, color: Color) {
        self.id = audioPathName ?? "__single_series"
        self.audioPathName = audioPathName
        self.color = color
    }
}

private struct PathLatencyChartMetrics {
    let successfulRecords: [MeasurementRecord]
    let successfulRecordsByAudioPath: [String: [MeasurementRecord]]
    let failureRecords: [MeasurementRecord]
    let timeRange: ClosedRange<Date>?
    let yAxisMax: Int

    init(records: [MeasurementRecord]) {
        var successes: [MeasurementRecord] = []
        var failures: [MeasurementRecord] = []
        var minTimestamp: Date?
        var maxTimestamp: Date?
        var maxLatency = 1

        successes.reserveCapacity(records.count)
        failures.reserveCapacity(records.count / 8)

        for record in records {
            minTimestamp = minTimestamp.map { min($0, record.timestamp) } ?? record.timestamp
            maxTimestamp = maxTimestamp.map { max($0, record.timestamp) } ?? record.timestamp

            if record.success, let latency = record.latencyMs {
                successes.append(record)
                maxLatency = max(maxLatency, latency)
            } else if !record.success {
                failures.append(record)
            }
        }

        let sortedSuccesses = successes.sorted { $0.timestamp < $1.timestamp }
        self.successfulRecords = sortedSuccesses
        self.successfulRecordsByAudioPath = Dictionary(grouping: sortedSuccesses, by: \.audioPathName)
        self.failureRecords = failures
        self.yAxisMax = Self.roundedYAxisMax(for: maxLatency)

        if let minTimestamp, let maxTimestamp {
            self.timeRange = minTimestamp == maxTimestamp
                ? minTimestamp.addingTimeInterval(-30) ... maxTimestamp.addingTimeInterval(30)
                : minTimestamp ... maxTimestamp
        } else {
            self.timeRange = nil
        }
    }

    private static func roundedYAxisMax(for raw: Int) -> Int {
        if raw <= 60 { return 60 }
        if raw <= 150 { return 150 }
        if raw <= 300 { return 300 }
        if raw <= 600 { return 600 }
        if raw <= 900 { return 900 }
        let rounded = Int(ceil(Double(raw) / 500.0) * 500.0)
        return max(rounded, raw)
    }
}

private struct PathLatencyChart: View {
    private let metrics: PathLatencyChartMetrics
    let series: [ChartSeriesStyle]
    let showsBars: Bool
    let showsAxes: Bool
    let showsArea: Bool

    private let leftAxisWidth: CGFloat = 52
    private let bottomAxisHeight: CGFloat = 28
    private let topPadding: CGFloat = 8
    private let rightPadding: CGFloat = 8

    private static let axisDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    init(records: [MeasurementRecord], series: [ChartSeriesStyle], showsBars: Bool, showsAxes: Bool, showsArea: Bool) {
        self.metrics = PathLatencyChartMetrics(records: records)
        self.series = series
        self.showsBars = showsBars
        self.showsAxes = showsAxes
        self.showsArea = showsArea
    }

    var body: some View {
        GeometryReader { geometry in
            let plotRect = CGRect(
                x: showsAxes ? leftAxisWidth : 0,
                y: topPadding,
                width: max(1, geometry.size.width - (showsAxes ? leftAxisWidth : 0) - rightPadding),
                height: max(1, geometry.size.height - topPadding - (showsAxes ? bottomAxisHeight : 0))
            )

            ZStack(alignment: .topLeading) {
                gridPath(in: plotRect)
                    .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                baselinePath(in: plotRect)
                    .stroke(Color.secondary.opacity(0.28), lineWidth: 1)

                ForEach(effectiveSeries) { style in
                    let points = coordinates(for: style, in: plotRect, metrics: metrics)

                    if showsArea {
                        areaPath(points: points, plotRect: plotRect)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [style.color.opacity(0.28), style.color.opacity(0.035)]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    if showsBars {
                        barsPath(points: points, plotRect: plotRect)
                            .stroke(style.color.opacity(0.22), lineWidth: 2)
                    }

                    linePath(points: points)
                        .stroke(style.color, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                }

                failuresPath(in: plotRect, metrics: metrics)
                    .stroke(Color.red.opacity(0.36), lineWidth: 1.2)

                if showsAxes {
                    axisOverlay(plotRect: plotRect, metrics: metrics)
                }
            }
        }
    }

    private var effectiveSeries: [ChartSeriesStyle] {
        series.isEmpty ? [ChartSeriesStyle(audioPathName: nil, color: .purple)] : series
    }

    private func records(for style: ChartSeriesStyle, metrics: PathLatencyChartMetrics) -> [MeasurementRecord] {
        if let audioPathName = style.audioPathName {
            return metrics.successfulRecordsByAudioPath[audioPathName, default: []]
        }
        return metrics.successfulRecords
    }

    private func coordinates(for style: ChartSeriesStyle, in plotRect: CGRect, metrics: PathLatencyChartMetrics) -> [CGPoint] {
        guard let timeRange = metrics.timeRange else { return [] }
        return records(for: style, metrics: metrics).compactMap { record in
            guard let latency = record.latencyMs else { return nil }
            return CGPoint(
                x: xPosition(for: record.timestamp, in: plotRect, timeRange: timeRange),
                y: yPosition(for: latency, in: plotRect, yAxisMax: metrics.yAxisMax)
            )
        }
    }

    private func gridPath(in plotRect: CGRect) -> Path {
        Path { path in
            for index in 1 ... 3 {
                let progress = CGFloat(index) / 3
                let y = plotRect.maxY - plotRect.height * progress
                path.move(to: CGPoint(x: plotRect.minX, y: y))
                path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            }

            for index in 0 ... 6 {
                let progress = CGFloat(index) / 6
                let x = plotRect.minX + plotRect.width * progress
                path.move(to: CGPoint(x: x, y: plotRect.minY))
                path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            }
        }
    }

    private func baselinePath(in plotRect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
            path.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        }
    }

    private func barsPath(points: [CGPoint], plotRect: CGRect) -> Path {
        Path { path in
            for point in points {
                path.move(to: CGPoint(x: point.x, y: plotRect.maxY))
                path.addLine(to: point)
            }
        }
    }

    private func areaPath(points: [CGPoint], plotRect: CGRect) -> Path {
        Path { path in
            guard points.count >= 2, let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: plotRect.maxY))
            path.addLine(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: last.x, y: plotRect.maxY))
            path.closeSubpath()
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func failuresPath(in plotRect: CGRect, metrics: PathLatencyChartMetrics) -> Path {
        Path { path in
            guard let timeRange = metrics.timeRange else { return }
            for record in metrics.failureRecords {
                let x = xPosition(for: record.timestamp, in: plotRect, timeRange: timeRange)
                path.move(to: CGPoint(x: x, y: plotRect.minY))
                path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            }
        }
    }

    private func axisOverlay(plotRect: CGRect, metrics: PathLatencyChartMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0 ... 3, id: \.self) { index in
                let progress = CGFloat(index) / 3
                let value = Int(round(Double(metrics.yAxisMax) * Double(progress)))
                Text("\(value)ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .position(x: leftAxisWidth / 2, y: plotRect.maxY - plotRect.height * progress)
            }

            if let timeRange = metrics.timeRange {
                ForEach(0 ... 3, id: \.self) { index in
                    let progress = Double(index) / 3.0
                    let date = timeRange.lowerBound.addingTimeInterval(timeRange.upperBound.timeIntervalSince(timeRange.lowerBound) * progress)
                    Text(Self.axisDateFormatter.string(from: date))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .position(x: plotRect.minX + plotRect.width * CGFloat(progress), y: plotRect.maxY + 18)
                }
            }
        }
    }

    private func xPosition(for date: Date, in plotRect: CGRect, timeRange: ClosedRange<Date>) -> CGFloat {
        let duration = max(timeRange.upperBound.timeIntervalSince(timeRange.lowerBound), 1)
        let progress = date.timeIntervalSince(timeRange.lowerBound) / duration
        return plotRect.minX + plotRect.width * CGFloat(min(1, max(0, progress)))
    }

    private func yPosition(for latency: Int, in plotRect: CGRect, yAxisMax: Int) -> CGFloat {
        let progress = CGFloat(min(1, max(0, Double(latency) / Double(max(yAxisMax, 1)))))
        return plotRect.maxY - plotRect.height * progress
    }
}

@available(macOS 13.0, *)
private struct ModernLatencyChart: View {
    let records: [MeasurementRecord]
    let color: Color
    let showsDenseBars: Bool
    let showsArea: Bool
    @State private var selectedDate: Date?

    var body: some View {
        if #available(macOS 14.0, *) {
            baseChart
                .chartXSelection(value: $selectedDate)
        } else {
            baseChart
        }
    }

    private var baseChart: some View {
        Chart {
            ForEach(records) { point in
                if let latency = point.latencyMs, point.success {
                    if showsArea {
                        AreaMark(
                            x: .value("时间", point.timestamp),
                            y: .value("延迟", latency)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.30), color.opacity(0.035)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("延迟", latency)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                    if showsDenseBars {
                        BarMark(
                            x: .value("时间", point.timestamp),
                            y: .value("延迟", latency)
                        )
                        .foregroundStyle(color.opacity(0.34))
                    }
                } else {
                    RuleMark(x: .value("失败时间", point.timestamp))
                        .foregroundStyle(.red.opacity(0.35))
                }
            }

            if let selectedDate {
                RuleMark(x: .value("选择时间", selectedDate))
                    .foregroundStyle(color.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .transaction { transaction in
            transaction.animation = nil
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let latency = value.as(Int.self) {
                        Text("\(latency)ms")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }
                }
            }
        }
    }
}

@available(macOS 13.0, *)
private struct ModernMenuLatencySparkline: View {
    let records: [MeasurementRecord]
    let color: Color

    var body: some View {
        Chart {
            ForEach(records) { point in
                if let latency = point.latencyMs, point.success {
                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("延迟", latency)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

                    BarMark(
                        x: .value("时间", point.timestamp),
                        y: .value("延迟", latency)
                    )
                    .foregroundStyle(color.opacity(0.38))
                } else {
                    RuleMark(x: .value("失败时间", point.timestamp))
                        .foregroundStyle(.red.opacity(0.45))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: true))
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

@available(macOS 13.0, *)
private struct ModernMultiLatencyChart: View {
    let records: [MeasurementRecord]
    let audioPathNames: [String]
    @State private var selectedDate: Date?

    private func color(for audioPathName: String) -> Color {
        let palette = AccentColorOption.all.map(\.color)
        guard let index = audioPathNames.firstIndex(of: audioPathName), !palette.isEmpty else {
            return .purple
        }
        return palette[index % palette.count]
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            baseChart
                .chartXSelection(value: $selectedDate)
        } else {
            baseChart
        }
    }

    private var baseChart: some View {
        Chart {
            ForEach(records) { point in
                if let latency = point.latencyMs, point.success {
                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("延迟", latency)
                    )
                    .foregroundStyle(by: .value("节点", point.audioPathName))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                } else {
                    RuleMark(x: .value("失败时间", point.timestamp))
                        .foregroundStyle(.red.opacity(0.28))
                }
            }

            if let selectedDate {
                RuleMark(x: .value("选择时间", selectedDate))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartForegroundStyleScale(
            domain: audioPathNames,
            range: audioPathNames.map { color(for: $0) }
        )
        .chartYScale(domain: .automatic(includesZero: true))
        .transaction { transaction in
            transaction.animation = nil
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let latency = value.as(Int.self) {
                        Text("\(latency)ms")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }
                }
            }
        }
    }
}

@available(macOS 12.0, *)
struct StatCard: View {
    let title: String
    let value: String
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text(title)
                .font((compact ? Font.footnote : Font.subheadline).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: compact ? 20 : 23, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 14 : 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .gentleAppear()
    }
}

@available(macOS 12.0, *)
struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panelAnimation: Animation? {
        reduceMotion ? nil : MotionTokens.soft
    }

    var body: some View {
        let menuAudioPathName = model.monitoredAudioPathNames.first ?? "System Audio Path"
        let stats = model.stats(for: menuAudioPathName)
        let records = model.chartData(hours: 4, audioPath: menuAudioPathName, maxTotalPoints: 180, minimumPointsPerSeries: 180)

        VStack(alignment: .leading, spacing: 10) {
            Text(menuAudioPathName)
                .font(.headline)

            HStack(alignment: .firstTextBaseline) {
                Text(stats.lastLatency.map { "\($0)" } ?? "--")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("ms")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(model.isRunning ? .green : .secondary)
                    .frame(width: 8, height: 8)
            }

            MenuLatencySparkline(records: records, color: model.accentColor)
                .frame(height: 86)
                .overlay {
                    if records.isEmpty {
                        Text(model.t("等待数据"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            HStack {
                Text(model.monitoringStatusText)
                Spacer()
                Text("\(model.monitoredAudioPathNames.count) \(model.t("节点")) · 4h \(model.t("趋势"))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            Button(model.t("立即探测")) {
                Task { await model.runMeasurement() }
            }
            Button(model.isRunning ? model.t("停止监控") : model.t("开始监控")) {
                model.isRunning ? model.stopMonitoring() : model.startMonitoring()
            }
        }
        .padding(14)
        .frame(width: 320)
        .compatibleTint(model.accentColor)
        .animation(panelAnimation, value: model.recordsRevision)
    }
}

@available(macOS 12.0, *)
struct StatusBarBridge: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> NSView {
        StatusBarController.shared.configure(model: model)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        StatusBarController.shared.configure(model: model)
        StatusBarController.shared.updateTitle()
    }
}

@available(macOS 12.0, *)
struct MacOS12StatusBarBridge: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if #available(macOS 13.0, *) {
            EmptyView()
        } else {
            StatusBarBridge(model: model)
        }
    }
}

@MainActor
@available(macOS 12.0, *)
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var model: AppModel?
    private var lastRenderedTitle = ""

    func configure(model: AppModel) {
        let modelChanged = self.model !== model
        self.model = model

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "AudioLink Lab")
            item.button?.imagePosition = .imageLeading
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            statusItem = item
        }

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            self.popover = popover
        }

        if modelChanged || popover?.contentViewController == nil {
            popover?.contentViewController = NSHostingController(
                rootView: MenuBarPanel()
                    .environmentObject(model)
            )
        }
        updateTitle()
    }

    func updateTitle() {
        guard let model, let button = statusItem?.button else { return }
        let latency = model.stats(for: model.monitoredAudioPathNames).lastLatency
        let title = latency.map { " \($0)ms" } ?? " --"
        guard title != lastRenderedTitle else { return }
        lastRenderedTitle = title
        button.title = title
    }

@objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainWindow()
        buildStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    private func showMainWindow() {
        if window == nil {
            buildMainWindow()
            return
        }

        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMainWindow() {
        let rootView = RootContentView()
            .environmentObject(model)

        let hostingController = NSHostingController(rootView: rootView)
        let usesIntegratedTitlebar = RuntimeFeaturePlan.current.usesSwiftUIAppLifecycle
        let styleMask: NSWindow.StyleMask = usesIntegratedTitlebar
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "AudioLink Lab"
        window.titleVisibility = usesIntegratedTitlebar ? .hidden : .visible
        window.titlebarAppearsTransparent = usesIntegratedTitlebar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(
            width: AudioLinkLayoutMetrics.minimumWindowWidth,
            height: AudioLinkLayoutMetrics.minimumWindowHeight
        )
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "AudioLink Lab")
                button.imagePosition = .imageLeading
            }
            button.title = " --"
            button.target = self
            button.action = #selector(toggleStatusPopover(_:))
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: RootContentView.compactMenu(model: model)
        )
        statusPopover = popover
    }

    @objc private func toggleStatusPopover(_ sender: NSStatusBarButton) {
        guard let popover = statusPopover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            refreshStatusTitle()
        }
    }

    private func refreshStatusTitle() {
        let latency = model.stats(for: model.monitoredAudioPathNames).lastLatency
        statusItem?.button?.title = latency.map { " \($0)ms" } ?? " --"
    }
}

struct RootContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if #available(macOS 12.0, *) {
            ModernContentView()
        } else {
            LegacyContentView()
        }
    }

    static func compactMenu(model: AppModel) -> some View {
        Group {
            if #available(macOS 12.0, *) {
                MenuBarPanel()
                    .environmentObject(model)
            } else {
                LegacyMenuPanel()
                    .environmentObject(model)
            }
        }
    }
}

@available(macOS 15.0, *)
struct SequoiaEnhancedContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entranceAnimation: Animation? {
        model.runtimeProfile.pageAnimation(reduceMotion: reduceMotion)
    }

    var body: some View {
        ModernContentView()
            .animation(entranceAnimation, value: model.accentColorID)
    }
}

struct LegacyContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedHours: Double = 24

    private var versionedMotionProfile: VersionedMotionProfile {
        VersionedMotionProfile(runtimeProfile: model.runtimeProfile, intensity: model.motionIntensity)
    }

    private var selectedRecords: [MeasurementRecord] {
        model.chartData(hours: selectedHours, audioPaths: model.monitoredAudioPathNames, maxTotalPoints: 420, minimumPointsPerSeries: 160)
    }

    var body: some View {
        HStack(spacing: 0) {
            legacySidebar
                .frame(width: 252)
                .background(legacySidebarBackground)
                .legacyAppear(index: 0, distance: 0)

            VStack(alignment: .leading, spacing: 16) {
                Text(model.t("节点监控"))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .fontWeight(.bold)
                    .legacyAppear(index: 1)

                LegacyStatsStrip(stats: model.stats(for: model.monitoredAudioPathNames), model: model)
                    .legacyAppear(index: 2)

                HStack {
                    Text(model.t("延迟曲线"))
                        .font(.headline)
                    Spacer()
                    Picker(model.t("时间范围"), selection: $selectedHours) {
                        Text("1h").tag(1.0)
                        Text("4h").tag(4.0)
                        Text("12h").tag(12.0)
                        Text("24h").tag(24.0)
                        Text("7d").tag(168.0)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 360)
                }
                .legacyAppear(index: 3)

                LegacyLatencyChart(records: selectedRecords, color: model.accentColor)
                    .id(selectedRecords.count)
                    .frame(height: 320)
                    .padding(12)
                    .legacy15Panel(cornerRadius: 16, accentColor: model.accentColor)
                    .legacyInteractiveCard()
                    .legacyAppear(index: 4, distance: 14)

                LegacyRecordsList(records: model.recentRecords(limit: 60), model: model)
                    .legacy15Panel(cornerRadius: 16, accentColor: model.accentColor)
                    .legacyAppear(index: 5, distance: 14)
            }
            .padding(20)
            .background(legacyDetailBackground)
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(legacyWindowBackground)
        .legacyAppear(index: 0, distance: 8)
        .legacyVersionedStartupMotion(profile: versionedMotionProfile)
    }

    private var legacySidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                legacySidebarSection(model.t("Language")) {
                    Picker("", selection: $model.languageCode) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }

                legacySidebarSection(model.t("动态效果")) {
                    Picker("", selection: $model.motionIntensityID) {
                        Text(model.t("增强")).tag(MotionIntensity.enhanced.rawValue)
                        Text(model.t("减弱")).tag(MotionIntensity.reduced.rawValue)
                        Text(model.t("无动画")).tag(MotionIntensity.none.rawValue)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }

                legacySidebarSection(model.t("主要颜色")) {
                    LegacyAccentColorStrip(model: model)
                }

                legacySidebarSection(model.t("控制")) {
                    Button(model.isRunning ? model.t("停止监控") : model.t("开始监控")) {
                        model.isRunning ? model.stopMonitoring() : model.startMonitoring()
                    }
                    .buttonStyle(Legacy15ControlButtonStyle(isProminent: true, accentColor: model.accentColor))

                    Button(model.t("立即探测")) {
                        Task { await model.runMeasurement() }
                    }
                    .buttonStyle(Legacy15ControlButtonStyle(isProminent: false, accentColor: model.accentColor))

                    Button(model.t("刷新代理列表")) {
                        Task { await model.refreshAudioPathCatalog() }
                    }
                    .buttonStyle(Legacy15ControlButtonStyle(isProminent: false, accentColor: model.accentColor))

                    Button(model.t("删除历史数据")) {
                        model.clearHistory()
                    }
                    .buttonStyle(Legacy15ControlButtonStyle(isProminent: false, accentColor: model.accentColor))
                }

                legacySidebarSection(model.t("设置")) {
                    LegacyFieldLabel(model.t("Input Device"))
                    TextField(model.t("Input Device"), text: $model.inputDeviceName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    LegacyFieldLabel(model.t("探测目标"))
                    TextField(model.t("探测目标"), text: $model.excitationSignalName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Picker(model.t("数据点间隔"), selection: $model.measurementIntervalMs) {
                        Text("5000").tag(5000)
                        Text("10000").tag(10000)
                        Text("30000").tag(30000)
                        Text("60000").tag(60000)
                        Text("120000").tag(120000)
                    }
                }

                legacySidebarSection(model.t("状态")) {
                    LegacyStatusLine(title: model.t("当前节点"), value: model.resolvedAudioPathName)
                    LegacyStatusLine(title: model.t("监控节点数"), value: "\(model.monitoredAudioPathNames.count)")
                    LegacyStatusLine(title: model.t("监控状态"), value: model.monitoringStatusText)
                }
            }
            .padding(14)
        }
    }

    private var legacyWindowBackground: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(NSColor.windowBackgroundColor).opacity(0.98),
                Color(NSColor.controlBackgroundColor).opacity(0.88)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var legacySidebarBackground: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(NSColor.controlBackgroundColor).opacity(0.88),
                Color(NSColor.windowBackgroundColor).opacity(0.72)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var legacyDetailBackground: some View {
        Color(NSColor.windowBackgroundColor).opacity(0.24)
    }

    private func legacySidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(10)
            .legacy15Panel(cornerRadius: 12, accentColor: model.accentColor)
        }
    }
}

struct LegacyFieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundColor(.secondary)
    }
}

struct LegacyStatusLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

struct LegacyAccentColorStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(AccentColorOption.all.chunked(into: 8).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    ForEach(row) { option in
                        Button {
                            model.accentColorID = option.id
                        } label: {
                            ZStack {
                                Capsule(style: .continuous)
                                    .fill(option.color)
                                    .frame(height: 14)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(model.accentColorID == option.id ? Color.primary.opacity(0.9) : Color.clear, lineWidth: 1.5)
                                    )
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 20)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(LegacyButtonMotionStyle())
                    }
                }
            }
        }
    }
}

struct LegacyStatsStrip: View {
    let stats: StatsSummary
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            LegacyStatCard(title: model.t("上次延迟"), value: stats.lastLatency.map { "\($0) ms" } ?? "--")
            LegacyStatCard(title: model.t("24h 平均延迟"), value: stats.avgLatency24h.map { String(format: "%.1f ms", $0) } ?? "--")
            LegacyStatCard(title: model.t("24h 最高延迟"), value: stats.clockDriftPPM.map { String(format: "%.2f ppm", $0) } ?? "--")
            LegacyStatCard(title: model.t("24h 丢包率"), value: stats.jitterMilliseconds.map { String(format: "%.2f ms", $0) } ?? "--")
            LegacyStatCard(title: model.t("24h 可用率"), value: stats.correlationConfidence.map { String(format: "%.1f%%", $0 * 100) } ?? "--")
        }
    }
}

struct LegacyStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .legacy15Panel(cornerRadius: 14, accentColor: .clear)
        .legacyInteractiveCard()
    }
}

struct LegacyLatencyChart: View {
    let records: [MeasurementRecord]
    let color: Color
    @State private var reveal: CGFloat = 0

    private var successes: [MeasurementRecord] {
        records.filter { $0.success && $0.latencyMs != nil }.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let rect = geometry.frame(in: .local).insetBy(dx: 40, dy: 24)
                    for index in 0 ... 3 {
                        let y = rect.maxY - rect.height * CGFloat(index) / 3
                        path.move(to: CGPoint(x: rect.minX, y: y))
                        path.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)

                Path { path in
                    let rect = geometry.frame(in: .local).insetBy(dx: 40, dy: 24)
                    guard let first = successes.first,
                          let last = successes.last
                    else { return }
                    let maxLatency = max(1, successes.compactMap(\.latencyMs).max() ?? 1)
                    let duration = max(last.timestamp.timeIntervalSince(first.timestamp), 1)
                    for (index, record) in successes.enumerated() {
                        guard let latency = record.latencyMs else { continue }
                        let x = rect.minX + rect.width * CGFloat(record.timestamp.timeIntervalSince(first.timestamp) / duration)
                        let y = rect.maxY - rect.height * CGFloat(Double(latency) / Double(maxLatency))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .trim(from: 0, to: reveal)
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                if successes.isEmpty {
                    Text(modelTextUnavailable)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            reveal = 0
            withAnimation(MotionTokens.legacyChart) {
                reveal = 1
            }
        }
    }

    private var modelTextUnavailable: String {
        "No latency data"
    }
}

struct LegacyRecordsList: View {
    let records: [MeasurementRecord]
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("最近记录"))
                .font(.headline)
            VStack(spacing: 0) {
                HStack {
                    Text(model.t("时间"))
                        .frame(width: 92, alignment: .leading)
                    Text(model.t("节点"))
                        .frame(width: 190, alignment: .leading)
                    Text(model.t("结果"))
                        .frame(width: 78, alignment: .leading)
                    Spacer()
                    Text(model.t("延迟"))
                        .frame(width: 72, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.58))

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(records) { record in
                            LegacyRecordRow(record: record, model: model)
                            Divider()
                                .opacity(0.42)
                        }
                        if records.isEmpty {
                            Text("--")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 220)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.09), lineWidth: 1)
            )
        }
        .padding(12)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}

struct LegacyRecordRow: View {
    let record: MeasurementRecord
    let model: AppModel

    var body: some View {
        HStack {
            Text(Self.timeFormatter.string(from: record.timestamp))
                .frame(width: 92, alignment: .leading)
            Text(record.audioPathName)
                .lineLimit(1)
                .frame(width: 190, alignment: .leading)
            Text(record.success ? model.t("成功") : model.t("失败"))
                .foregroundColor(record.success ? .green : .red)
                .frame(width: 78, alignment: .leading)
            Spacer()
            Text(record.latencyMs.map { "\($0) ms" } ?? "--")
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.34))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}

struct LegacyMenuPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.monitoredAudioPathNames.first ?? "System Audio Path")
                .font(.headline)
            Text(model.stats(for: model.monitoredAudioPathNames).lastLatency.map { "\($0) ms" } ?? "--")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Button(model.t("立即探测")) {
                Task { await model.runMeasurement() }
            }
            .buttonStyle(LegacyButtonMotionStyle())
            Button(model.isRunning ? model.t("停止监控") : model.t("开始监控")) {
                model.isRunning ? model.stopMonitoring() : model.startMonitoring()
            }
            .buttonStyle(LegacyButtonMotionStyle())
        }
        .padding(14)
        .frame(width: 260)
    }
}
