import Foundation
import FamilyControls
import DeviceActivity
import ManagedSettings
import UserNotifications
import OSLog

/// 诊断日志。使用 .public 的只有固定文案，动态内容默认按 .private 脱敏，
/// 避免把用户的使用时长细节写进系统日志。
private let eyeBreakLog = Logger(subsystem: "com.eyebreak.app", category: "detection")

// MARK: - 名称（与 Monitor 扩展保持一致）

extension DeviceActivityName {
    static let eyeBreakUsage  = DeviceActivityName("com.eyebreak.monitor.usage")
    static let shieldWatchdog = DeviceActivityName("com.eyebreak.monitor.shieldWatchdog")
}

extension DeviceActivityEvent.Name {
    static func milestone(_ minutes: Int) -> Self { Self("eyebreak.milestone.\(minutes)") }
}

/// 用户对一次护眼提醒的处理结果。三者必须分开统计，
/// 否则「今日护眼次数」把跳过也算进去，习惯报告就没有可信度。
enum BreakOutcome {
    case completed
    case skipped
    case snoozed
}

// MARK: - Manager

@MainActor
class ScreenTimeManager: ObservableObject {

    @Published var authStatus: AuthorizationStatus = .notDetermined
    @Published var isMonitoring = false

    /// 目标连续用屏分钟数。真机 POC 阶段先设 2–5 分钟（v0.3 步骤 2），正式为 30。
    /// 写入共享存储后，扩展读取同一个值，保证三个 target 阈值与文案一致。
    @Published var targetMinutes: Int = EyeBreakConfig.defaultTargetMinutes
    @Published var layer3Minutes: Int = EyeBreakConfig.defaultLayer3Minutes

    // Layer 1
    @Published var longestActivityMinutes: Double = 0
    @Published var layer1WrittenAt: Date?
    @Published var appleLastUpdatedDate: Date?
    @Published var layer1IsFresh = false
    @Published var segmentCount = 0

    // Layer 2
    @Published var lastMilestoneMinutes = 0
    @Published var observedDensity: Double = 0

    // Layer 3
    @Published var totalActivityMinutes: Double = 0

    @Published var activeLayer: String = ""
    @Published var showEyeBreak = false
    @Published var log: [String] = []

    /// 面向用户的可执行错误说明（授权被拒、启动失败等）
    @Published var statusMessage: String?

    // 当日结果统计
    @Published var completedCount = 0
    @Published var skippedCount = 0
    @Published var snoozedCount = 0

    private let center = DeviceActivityCenter()
    private let store  = ManagedSettingsStore()
    private var refreshTimer: Timer?

    init() {
        authStatus = AuthorizationCenter.shared.authorizationStatus
        let db = UserDefaults.eyeBreak
        db.eb_resetDailyStateIfNeeded()
        targetMinutes = db.eb_targetMinutes
        layer3Minutes = db.eb_layer3Minutes
        reconcileMonitoringState()
        startRefreshTimer()
    }

    // MARK: - 授权

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            authStatus = AuthorizationCenter.shared.authorizationStatus
            addLog("授权：\(authStatus)")
            if authStatus == .approved {
                statusMessage = nil
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            } else {
                statusMessage = "Screen Time 授权未通过。请到「设置 → 屏幕使用时间」中允许 EyeBreak，或重新点击申请授权。"
            }
        } catch {
            authStatus = AuthorizationCenter.shared.authorizationStatus
            statusMessage = "授权失败：\(error.localizedDescription)。请确认设备已开启屏幕使用时间，且本 App 具备 Family Controls 权限。"
            addLog("授权失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 监测状态

    /// 以系统实际注册的活动为准，而不是内存里的布尔值。
    /// App 重启后界面才不会显示「未启动」而系统其实仍在监测。
    func reconcileMonitoringState() {
        let active = center.activities.contains(.eyeBreakUsage)
        isMonitoring = active
        UserDefaults.eyeBreak.set(active, forKey: EyeBreakKey.monitoringIntended)
    }

    func startMonitoring() {
        let db = UserDefaults.eyeBreak
        db.set(targetMinutes, forKey: EyeBreakKey.targetMinutes)
        db.set(layer3Minutes, forKey: EyeBreakKey.layer3Minutes)
        db.eb_resetDetectionState()
        db.eb_clearTriggerState()
        db.removeObject(forKey: EyeBreakKey.cooldownUntil)

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
            intervalEnd:   DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true
        )

        let steps = EyeBreakConfig.milestones(for: targetMinutes)
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for m in steps {
            events[.milestone(m)] = DeviceActivityEvent(
                applications: [],   // 空集合 = 覆盖全部 App / 类别 / 网站
                categories: [],
                webDomains: [],
                threshold: DateComponents(minute: m)
            )
        }

        do {
            try center.startMonitoring(.eyeBreakUsage, during: schedule, events: events)
            statusMessage = nil
            addLog("监测启动 — 目标 \(targetMinutes) 分钟连续 | 里程碑 \(steps.map(String.init).joined(separator: "/")) 分钟")
            addLog("连续判定：\(EyeBreakConfig.continuityUsageSpan(for: targetMinutes)) 分钟用量须在 \(EyeBreakConfig.continuityWallLimit(for: targetMinutes)) 分钟真实时间内完成")
        } catch {
            statusMessage = "启动监测失败：\(error.localizedDescription)"
            addLog("启动失败：\(error.localizedDescription)")
        }
        reconcileMonitoringState()
    }

    func stopMonitoring() {
        center.stopMonitoring([.eyeBreakUsage, .shieldWatchdog])
        unshield()
        UserDefaults.eyeBreak.eb_clearTriggerState()
        reconcileMonitoringState()
        addLog("监测已停止，Shield 已解除")
    }

    // MARK: - 护眼流程

    func manualTrigger() {
        addLog("手动触发")
        showEyeBreak = true
    }

    /// 结束一次护眼提醒。outcome 决定计入哪一类统计。
    func finishEyeBreak(_ outcome: BreakOutcome) {
        let db = UserDefaults.eyeBreak

        let key: String
        let label: String
        switch outcome {
        case .completed: key = EyeBreakKey.completedCount; label = "完成护眼 🎉"
        case .skipped:   key = EyeBreakKey.skippedCount;   label = "跳过动作"
        case .snoozed:   key = EyeBreakKey.snoozedCount;   label = "稍后再说"
        }
        let count = db.integer(forKey: key) + 1
        db.set(count, forKey: key)

        let until = Date().addingTimeInterval(Double(EyeBreakConfig.cooldownMinutes * 60))
        db.set(until, forKey: EyeBreakKey.cooldownUntil)
        db.eb_clearTriggerState()
        unshield()
        showEyeBreak = false
        syncCounts()

        addLog("\(label)（今日第 \(count) 次），冷却至 \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short))")
    }

    func unshield() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories   = nil
        UserDefaults.eyeBreak.removeObject(forKey: EyeBreakKey.shieldAppliedAt)
        center.stopMonitoring([.shieldWatchdog])
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["eyebreak-recovery"])
    }

    /// 兜底：Shield 超时未解除则强制清掉
    func releaseShieldIfStale() {
        guard UserDefaults.eyeBreak.eb_shieldIsStale else { return }
        unshield()
        UserDefaults.eyeBreak.eb_clearTriggerState()
        addLog("⚠️ Shield 超时，已自动解除")
    }

    /// 紧急解除：通知里的「立即解除」动作与界面按钮共用
    func emergencyRelease() {
        unshield()
        UserDefaults.eyeBreak.eb_clearTriggerState()
        showEyeBreak = false
        addLog("已强制解除 Shield")
    }

    // MARK: - 同步

    func syncFromDefaults() {
        let db = UserDefaults.eyeBreak
        db.eb_resetDailyStateIfNeeded()
        releaseShieldIfStale()

        longestActivityMinutes = db.double(forKey: EyeBreakKey.longestActivitySeconds) / 60
        layer1WrittenAt        = db.object(forKey: EyeBreakKey.longestActivityUpdatedAt) as? Date
        appleLastUpdatedDate   = db.object(forKey: EyeBreakKey.appleLastUpdatedDate) as? Date
        layer1IsFresh          = db.eb_layer1IsFresh
        segmentCount           = db.integer(forKey: EyeBreakKey.segmentCount)
        totalActivityMinutes   = db.double(forKey: EyeBreakKey.totalActivitySeconds) / 60
        lastMilestoneMinutes   = db.integer(forKey: EyeBreakKey.lastMilestoneMinutes)
        observedDensity        = db.double(forKey: EyeBreakKey.observedDensity)
        activeLayer            = db.eb_activeLayer
        syncCounts()

        // Layer 1：只有数据新鲜才采信
        if layer1IsFresh,
           db.double(forKey: EyeBreakKey.longestActivitySeconds) >= Double(targetMinutes * 60),
           !db.eb_inCooldown,
           !db.eb_alreadyTriggered {
            db.set(true, forKey: EyeBreakKey.shouldShowEyeBreak)
            db.set("1",  forKey: EyeBreakKey.activeLayer)
            addLog("Layer 1 触发：longestActivity = \(String(format: "%.1f", longestActivityMinutes)) 分钟")
        }

        if db.eb_alreadyTriggered, !showEyeBreak {
            showEyeBreak = true
        }
    }

    private func syncCounts() {
        let db = UserDefaults.eyeBreak
        completedCount = db.integer(forKey: EyeBreakKey.completedCount)
        skippedCount   = db.integer(forKey: EyeBreakKey.skippedCount)
        snoozedCount   = db.integer(forKey: EyeBreakKey.snoozedCount)
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncFromDefaults() }
        }
    }

    func addLog(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(ts)] \(msg)"
        log.append(entry)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        eyeBreakLog.debug("\(msg, privacy: .private)")
    }
}
