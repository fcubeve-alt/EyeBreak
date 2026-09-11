import Foundation

// MARK: - 配置

enum EyeBreakConfig {
    static let appGroupID = "group.com.eyebreak.shared"

    /// 目标：约 30 分钟连续用屏触发（v0.4 第五节 A/B 级）
    static let defaultTargetMinutes = 30
    /// Layer 3 保底：45 分钟级柔性提醒（v0.4 第五节 C 级明确为 45–60 分钟）
    static let defaultLayer3Minutes = 45
    /// 休息多久算「充分休息」，超过则连续链重置（v0.3 Kill Test #1 场景 2：休息 5 分钟以上应重新计时）
    static let restGapMinutes = 5
    /// Layer 1 数据超过这个时长未刷新就不再信任（防止昨天的长会话today误触发）
    static let layer1MaxStalenessMinutes = 15
    /// Shield 最长存在时间，超时自动解除（防止扩展失效把用户所有 App 锁死）
    static let shieldMaxMinutes = 20
    /// 用户关闭提醒后的冷却期（v0.4 第六节：不能几分钟后再次弹出）
    static let cooldownMinutes = 15
    /// 连续性判定容差：N 分钟用量必须在 N × 1.4 的真实时钟内跑完才算连续
    static let densityTolerance = 1.4

    // MARK: 派生值

    /// 里程碑间隔。target=30 → step=5
    static func step(for target: Int) -> Int { max(1, target / 6) }

    /// 递增阈值列表。
    /// 关键：DeviceActivityEvent 的 threshold 在一个监测区间内**只触发一次**，不会重新武装。
    /// 所以不能靠「同一个阈值反复回调」数窗口，必须铺一排递增阈值，
    /// 靠两次回调之间的真实时钟间隔反推使用密度。
    static func milestones(for target: Int) -> [Int] {
        let s = step(for: target)
        var out: [Int] = []
        var v = s
        while v <= target * 6 && out.count < 20 {
            out.append(v)
            v += s
        }
        return out
    }

    /// 连续性回看的用量跨度。target=30 → 25 分钟
    static func continuityUsageSpan(for target: Int) -> Int {
        max(1, target - step(for: target))
    }

    /// 上述用量跨度允许占用的最大真实时钟。25 × 1.4 → 35 分钟
    static func continuityWallLimit(for target: Int) -> Int {
        Int((Double(continuityUsageSpan(for: target)) * densityTolerance).rounded())
    }
}

// MARK: - 共享存储的键

enum EyeBreakKey {
    // 配置（主 App 写入 → 扩展读取，保证测试阈值对所有 target 一致生效）
    static let targetMinutes = "eyebreak.cfg.targetMinutes"
    static let layer3Minutes = "eyebreak.cfg.layer3Minutes"

    // Layer 1（DeviceActivityReport 扩展写入）
    static let longestActivitySeconds   = "eyebreak.longestActivitySeconds"
    static let longestActivityUpdatedAt = "eyebreak.longestActivityUpdatedAt"  // 我们的写入时刻
    static let appleLastUpdatedDate     = "eyebreak.appleLastUpdatedDate"      // Apple 的 lastUpdatedDate（POC 1）
    static let segmentIntervalStart     = "eyebreak.segmentIntervalStart"      // POC 1
    static let segmentIntervalEnd       = "eyebreak.segmentIntervalEnd"        // POC 1
    static let segmentCount             = "eyebreak.segmentCount"
    static let totalActivitySeconds     = "eyebreak.totalActivitySeconds"

    // Layer 2（Monitor 扩展维护）
    static let milestoneHits        = "eyebreak.milestoneHits"        // [String(分钟): Double(epoch)]
    static let lastMilestoneMinutes = "eyebreak.lastMilestoneMinutes"
    static let lastMilestoneAt      = "eyebreak.lastMilestoneAt"
    static let observedDensity      = "eyebreak.observedDensity"      // 用量/时钟，1.0 = 全程在用

    // Layer 3
    static let lastLayer3Milestone = "eyebreak.lastLayer3Milestone"

    // 触发与交互状态
    static let activeLayer        = "eyebreak.activeLayer"   // "1","2","3",""
    static let shouldShowEyeBreak = "eyebreak.shouldShowEyeBreak"
    static let cooldownUntil      = "eyebreak.cooldownUntil"
    static let shieldAppliedAt    = "eyebreak.shieldAppliedAt"
    static let dayStamp           = "eyebreak.dayStamp"

    // 监测状态（持久化，避免 App 重启后界面与系统实际注册状态不一致）
    static let monitoringIntended = "eyebreak.monitoringIntended"

    // 结果计数：完成 / 跳过 / 稍后，三者必须分开，否则习惯统计没有可信度
    static let completedCount = "eyebreak.completedCount"
    static let skippedCount   = "eyebreak.skippedCount"
    static let snoozedCount   = "eyebreak.snoozedCount"
}

// MARK: - 用户可见文案
//
// 阈值可由用户在 2–60 分钟之间调整，所以任何「约 30 分钟」之类的写死文案都会
// 和事实不符。Shield 扩展与护眼页一律通过这里按实际阈值生成文案。

enum EyeBreakCopy {
    static func subtitle(layer: String, targetMinutes: Int, layer3Minutes: Int) -> String {
        switch layer {
        case "3":
            return "今天累计用屏已超过 \(layer3Minutes) 分钟\n抽 20 秒放松一下眼睛 💚"
        default:
            return "您已持续使用屏幕约 \(targetMinutes) 分钟\n让眼睛休息一下吧 ✨"
        }
    }

    static func notificationBody(layer: String, targetMinutes: Int, layer3Minutes: Int) -> String {
        switch layer {
        case "3":
            return "今天累计用屏已超过 \(layer3Minutes) 分钟，抽 20 秒放松一下眼睛。"
        default:
            return "您已持续使用屏幕约 \(targetMinutes) 分钟，请做一下护眼动作。"
        }
    }
}

// MARK: - 通知标识符（主 App 与 Monitor 扩展共用）

enum EyeBreakNotification {
    static let category      = "EYEBREAK"
    static let actionExercise = "EYEBREAK_EXERCISE"
    static let actionDismiss  = "EYEBREAK_DISMISS"
    /// 紧急解除：非前台动作，系统会在后台唤起主 App 执行解除，
    /// 是 Shield 卡住时不依赖用户手动打开 App 的恢复通道。
    static let actionRelease  = "EYEBREAK_RELEASE_SHIELD"
    static let categoryRecovery = "EYEBREAK_RECOVERY"
}

// MARK: - 共享 UserDefaults 与通用判断

extension UserDefaults {
    static var eyeBreak: UserDefaults {
        UserDefaults(suiteName: EyeBreakConfig.appGroupID)!
    }

    var eb_targetMinutes: Int {
        let v = integer(forKey: EyeBreakKey.targetMinutes)
        return v > 0 ? v : EyeBreakConfig.defaultTargetMinutes
    }

    var eb_layer3Minutes: Int {
        let v = integer(forKey: EyeBreakKey.layer3Minutes)
        return v > 0 ? v : EyeBreakConfig.defaultLayer3Minutes
    }

    var eb_inCooldown: Bool {
        guard let until = object(forKey: EyeBreakKey.cooldownUntil) as? Date else { return false }
        return Date() < until
    }

    var eb_alreadyTriggered: Bool { bool(forKey: EyeBreakKey.shouldShowEyeBreak) }

    /// Layer 1 数据是否足够新鲜。陈旧数据一律不采信。
    var eb_layer1IsFresh: Bool {
        guard let t = object(forKey: EyeBreakKey.longestActivityUpdatedAt) as? Date else { return false }
        return Date().timeIntervalSince(t) <= Double(EyeBreakConfig.layer1MaxStalenessMinutes * 60)
    }

    /// Shield 是否已超时（兜底：扩展失效时不能把用户锁死）
    var eb_shieldIsStale: Bool {
        guard let t = object(forKey: EyeBreakKey.shieldAppliedAt) as? Date else { return false }
        return Date().timeIntervalSince(t) > Double(EyeBreakConfig.shieldMaxMinutes * 60)
    }

    /// 当前触发层级（"1"/"2"/"3"/""）
    var eb_activeLayer: String { string(forKey: EyeBreakKey.activeLayer) ?? "" }

    /// 按真实阈值与触发层级生成的用户可见文案
    var eb_triggerSubtitle: String {
        EyeBreakCopy.subtitle(layer: eb_activeLayer,
                              targetMinutes: eb_targetMinutes,
                              layer3Minutes: eb_layer3Minutes)
    }

    /// 跨天时清空检测状态与当日计数
    func eb_resetDailyStateIfNeeded() {
        let today = Self.eb_dayString(Date())
        guard string(forKey: EyeBreakKey.dayStamp) != today else { return }
        set(today, forKey: EyeBreakKey.dayStamp)
        eb_resetDetectionState()
        set(0, forKey: EyeBreakKey.completedCount)
        set(0, forKey: EyeBreakKey.skippedCount)
        set(0, forKey: EyeBreakKey.snoozedCount)
    }

    /// 清除触发标志与 Shield 时间戳。调用方负责实际清空 ManagedSettingsStore。
    func eb_clearTriggerState() {
        set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
        set("",    forKey: EyeBreakKey.activeLayer)
        removeObject(forKey: EyeBreakKey.shieldAppliedAt)
    }

    func eb_resetDetectionState() {
        removeObject(forKey: EyeBreakKey.milestoneHits)
        removeObject(forKey: EyeBreakKey.lastMilestoneMinutes)
        removeObject(forKey: EyeBreakKey.lastMilestoneAt)
        removeObject(forKey: EyeBreakKey.lastLayer3Milestone)
        removeObject(forKey: EyeBreakKey.longestActivitySeconds)
        removeObject(forKey: EyeBreakKey.longestActivityUpdatedAt)
        removeObject(forKey: EyeBreakKey.appleLastUpdatedDate)
        set(0.0, forKey: EyeBreakKey.totalActivitySeconds)
        set(0.0, forKey: EyeBreakKey.observedDensity)
    }

    static func eb_dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
