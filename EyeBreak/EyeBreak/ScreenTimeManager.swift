import Foundation
import FamilyControls
import DeviceActivity
import ManagedSettings
import UserNotifications

// MARK: - 名称（与 Monitor 扩展保持一致）

extension DeviceActivityName {
    static let eyeBreakUsage = DeviceActivityName("com.eyebreak.monitor.usage")
    // 旧版本遗留，stopMonitoring 时一并停掉
    static let legacyWindowed = DeviceActivityName("com.eyebreak.monitor.windowed")
    static let legacyDaily    = DeviceActivityName("com.eyebreak.monitor.daily")
}

extension DeviceActivityEvent.Name {
    static func milestone(_ minutes: Int) -> Self { Self("eyebreak.milestone.\(minutes)") }
}

// MARK: - Manager

@MainActor
class ScreenTimeManager: ObservableObject {

    @Published var authStatus: AuthorizationStatus = .notDetermined
    @Published var isMonitoring = false

    /// 目标连续用屏分钟数。真机 POC 阶段先设 2–5 分钟（v0.3 步骤 2），正式为 30。
    /// 这个值会写入共享存储，扩展读取同一个值，保证三个 target 阈值一致。
    @Published var targetMinutes: Int = EyeBreakConfig.defaultTargetMinutes
    @Published var layer3Minutes: Int = EyeBreakConfig.defaultLayer3Minutes

    // Layer 1
    @Published var longestActivityMinutes: Double = 0
    @Published var layer1WrittenAt: Date?        // 我们写入的时刻
    @Published var appleLastUpdatedDate: Date?   // Apple 的 lastUpdatedDate（POC 1）
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

    private let center = DeviceActivityCenter()
    private let store  = ManagedSettingsStore()
    private var refreshTimer: Timer?

    init() {
        authStatus = AuthorizationCenter.shared.authorizationStatus
        let db = UserDefaults.eyeBreak
        db.eb_resetDailyStateIfNeeded()
        targetMinutes = db.eb_targetMinutes
        layer3Minutes = db.eb_layer3Minutes
        startRefreshTimer()
    }

    // MARK: - 授权

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            authStatus = AuthorizationCenter.shared.authorizationStatus
            addLog("授权：\(authStatus)")
            if authStatus == .approved {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            }
        } catch {
            addLog("授权失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 启动监测

    func startMonitoring() {
        let db = UserDefaults.eyeBreak
        // 配置下发给扩展（修复：过去扩展硬编码 30 分钟，测试阈值根本传不进去）
        db.set(targetMinutes, forKey: EyeBreakKey.targetMinutes)
        db.set(layer3Minutes, forKey: EyeBreakKey.layer3Minutes)
        db.eb_resetDetectionState()
        db.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
        db.set("",    forKey: EyeBreakKey.activeLayer)
        db.removeObject(forKey: EyeBreakKey.cooldownUntil)

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
            intervalEnd:   DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true
        )

        // 一排递增阈值。每个阈值在本区间内只会触发一次，
        // Monitor 靠相邻两次回调的时钟间隔判断使用密度。
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
            isMonitoring = true
            addLog("监测启动 — 目标 \(targetMinutes) 分钟连续 | 里程碑 \(steps.map(String.init).joined(separator: "/")) 分钟")
            addLog("连续判定：\(EyeBreakConfig.continuityUsageSpan(for: targetMinutes)) 分钟用量须在 \(EyeBreakConfig.continuityWallLimit(for: targetMinutes)) 分钟真实时间内完成")
        } catch {
            addLog("启动失败：\(error.localizedDescription)")
        }
    }

    func stopMonitoring() {
        center.stopMonitoring([.eyeBreakUsage, .legacyWindowed, .legacyDaily])
        isMonitoring = false
        unshield()
        let db = UserDefaults.eyeBreak
        db.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
        db.set("",    forKey: EyeBreakKey.activeLayer)
        addLog("监测已停止，Shield 已解除")
    }

    // MARK: - 护眼流程

    func manualTrigger() {
        addLog("手动触发")
        showEyeBreak = true
    }

    func dismissEyeBreak() {
        let until = Date().addingTimeInterval(Double(EyeBreakConfig.cooldownMinutes * 60))
        let db = UserDefaults.eyeBreak
        db.set(until, forKey: EyeBreakKey.cooldownUntil)
        db.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
        db.set("",    forKey: EyeBreakKey.activeLayer)
        unshield()
        showEyeBreak = false
        addLog("已关闭，冷却至 \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short))")
    }

    func completeEyeBreak() {
        let db = UserDefaults.eyeBreak
        let count = db.integer(forKey: EyeBreakKey.eyeBreakCount) + 1
        db.set(count, forKey: EyeBreakKey.eyeBreakCount)
        dismissEyeBreak()
        addLog("护眼完成 🎉 今日第 \(count) 次")
    }

    func unshield() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories   = nil
        UserDefaults.eyeBreak.removeObject(forKey: EyeBreakKey.shieldAppliedAt)
    }

    /// 兜底：Shield 超时未解除则强制清掉，避免用户被锁死
    func releaseShieldIfStale() {
        guard UserDefaults.eyeBreak.eb_shieldIsStale else { return }
        unshield()
        let db = UserDefaults.eyeBreak
        db.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
        db.set("",    forKey: EyeBreakKey.activeLayer)
        addLog("⚠️ Shield 超时，已自动解除")
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
        activeLayer            = db.string(forKey: EyeBreakKey.activeLayer) ?? ""

        // Layer 1：只有数据新鲜才采信（修复：陈旧的昨日长会话会误触发）
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
        print("EyeBreak: \(entry)")
    }
}
