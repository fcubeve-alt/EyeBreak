// DeviceActivityMonitor Extension
//
// Layer 1: 读取 Report 扩展写入的 longestActivity（带新鲜度校验）
// Layer 2: 递增阈值里程碑 + 使用密度判定「连续用屏」
// Layer 3: 45 分钟级日总量柔性提醒（v0.4 第五节 C 级）
//
// 为什么不是「数 5 分钟窗口」：
//   DeviceActivityEvent 的 threshold 在一个监测区间内只触发一次，不会重新武装，
//   而 DeviceActivitySchedule 的区间最短 15 分钟——5 分钟滚动窗口在 API 层面建不出来。
//   所以改为：铺一排递增阈值（累计用量 5/10/15…分钟各一个事件），
//   每次回调记录真实时钟，用「用量增量 ÷ 时钟增量」得到使用密度。
//   连续使用 → 密度接近 1；中途休息 → 时钟被拉长，密度掉下来，连续链断开。

import DeviceActivity
import ManagedSettings
import UserNotifications
import Foundation

// MARK: - 名称

extension DeviceActivityName {
    static let eyeBreakUsage = DeviceActivityName("com.eyebreak.monitor.usage")
}

extension DeviceActivityEvent.Name {
    static func milestone(_ minutes: Int) -> Self { Self("eyebreak.milestone.\(minutes)") }

    /// 从事件名反解出这次回调对应多少分钟累计用量
    var eb_milestoneMinutes: Int? {
        let prefix = "eyebreak.milestone."
        guard rawValue.hasPrefix(prefix) else { return nil }
        return Int(rawValue.dropFirst(prefix.count))
    }
}

// MARK: - Monitor

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let store = ManagedSettingsStore()
    private var db: UserDefaults { UserDefaults.eyeBreak }

    // MARK: 区间生命周期

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // 新的一天开始：清空里程碑链、Layer 1 缓存、当日计数
        db.eb_resetDetectionState()
        db.set(UserDefaults.eb_dayString(Date()), forKey: EyeBreakKey.dayStamp)
        db.set(0, forKey: EyeBreakKey.eyeBreakCount)
        releaseShieldIfStale()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        releaseShieldIfStale()
    }

    // MARK: 阈值回调

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)

        db.eb_resetDailyStateIfNeeded()
        releaseShieldIfStale()

        guard let minutes = event.eb_milestoneMinutes else { return }
        let now = Date()

        // 无论是否处于冷却，都要维护里程碑链，否则冷却结束后密度判定会失真
        recordMilestone(minutes: minutes, at: now)

        guard !db.eb_inCooldown, !db.eb_alreadyTriggered else { return }

        if checkLayer1() { return }
        if checkLayer2(currentMinutes: minutes, now: now) { return }
        checkLayer3(currentMinutes: minutes)
    }

    // MARK: - 里程碑记录（含「充分休息则重置」）

    private func recordMilestone(minutes: Int, at now: Date) {
        var hits = db.dictionary(forKey: EyeBreakKey.milestoneHits) as? [String: Double] ?? [:]

        let lastMinutes = db.integer(forKey: EyeBreakKey.lastMilestoneMinutes)
        if lastMinutes > 0,
           let lastAt = db.object(forKey: EyeBreakKey.lastMilestoneAt) as? Date {
            let usageDelta = Double(minutes - lastMinutes)          // 预期 ≈ step
            let wallDelta  = now.timeIntervalSince(lastAt) / 60     // 实际耗费的真实时间
            // 真实时间比用量多出 restGapMinutes 以上 → 中途确实放下了设备
            if wallDelta - usageDelta > Double(EyeBreakConfig.restGapMinutes) {
                hits.removeAll()   // v0.3 Kill Test #1 场景 2/3：连续链重置
            }
        }

        hits["\(minutes)"] = now.timeIntervalSince1970
        db.set(hits, forKey: EyeBreakKey.milestoneHits)
        db.set(minutes, forKey: EyeBreakKey.lastMilestoneMinutes)
        db.set(now, forKey: EyeBreakKey.lastMilestoneAt)
    }

    // MARK: - Layer 1：longestActivity（最优先，但必须新鲜）

    private func checkLayer1() -> Bool {
        guard db.eb_layer1IsFresh else { return false }
        let thresholdSeconds = Double(db.eb_targetMinutes * 60)
        guard db.double(forKey: EyeBreakKey.longestActivitySeconds) >= thresholdSeconds else {
            return false
        }
        trigger(layer: "1")
        return true
    }

    // MARK: - Layer 2：使用密度判定连续用屏

    private func checkLayer2(currentMinutes: Int, now: Date) -> Bool {
        let target = db.eb_targetMinutes
        let span = EyeBreakConfig.continuityUsageSpan(for: target)          // 例：25 分钟用量
        let wallLimit = Double(EyeBreakConfig.continuityWallLimit(for: target)) // 例：35 分钟时钟

        guard let hits = db.dictionary(forKey: EyeBreakKey.milestoneHits) as? [String: Double]
        else { return false }

        // 锚点 = 用量上至少落后 span 分钟、且尽量靠近当前的那个里程碑
        let anchor = hits.compactMap { key, epoch -> (minutes: Int, at: Date)? in
            guard let m = Int(key), currentMinutes - m >= span else { return nil }
            return (m, Date(timeIntervalSince1970: epoch))
        }.max { $0.minutes < $1.minutes }

        guard let anchor else { return false }

        let wallDelta = now.timeIntervalSince(anchor.at) / 60
        let usageDelta = Double(currentMinutes - anchor.minutes)
        db.set(usageDelta / max(wallDelta, 0.1), forKey: EyeBreakKey.observedDensity)

        // usageDelta 分钟的用量在 wallDelta 分钟内跑完 → 密度够高即判为连续
        guard wallDelta <= wallLimit else { return false }
        trigger(layer: "2")
        return true
    }

    // MARK: - Layer 3：45 分钟级保底柔性提醒

    private func checkLayer3(currentMinutes: Int) {
        let l3 = db.eb_layer3Minutes
        guard currentMinutes >= l3 else { return }
        // 距上次 Layer 3 提醒必须再累积满一个 l3 的用量，保证 45–60 分钟级的节奏
        let last = db.integer(forKey: EyeBreakKey.lastLayer3Milestone)
        guard currentMinutes - last >= l3 else { return }
        db.set(currentMinutes, forKey: EyeBreakKey.lastLayer3Milestone)
        trigger(layer: "3")
    }

    // MARK: - 触发

    private func trigger(layer: String) {
        db.set(true,  forKey: EyeBreakKey.shouldShowEyeBreak)
        db.set(layer, forKey: EyeBreakKey.activeLayer)
        db.set(Date(), forKey: EyeBreakKey.shieldAppliedAt)

        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories   = .all()

        let content = UNMutableNotificationContent()
        content.title = "眼睛需要休息了"
        content.body  = layer == "3"
            ? "今天用屏时间不少了，抽 20 秒放松一下眼睛吧。"
            : "您已持续使用屏幕约\(db.eb_targetMinutes)分钟，请做一下护眼动作。"
        content.sound = .default
        content.categoryIdentifier = "EYEBREAK"

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "eyebreak-\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            ),
            withCompletionHandler: nil
        )
    }

    // MARK: - Shield 兜底

    /// Shield 挡住全部 App。一旦 ShieldAction 扩展启动失败，用户会被锁死，
    /// 所以每次扩展被唤醒时都检查一次超时并强制解除。
    private func releaseShieldIfStale() {
        guard db.eb_shieldIsStale else { return }
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories   = nil
        db.removeObject(forKey: EyeBreakKey.shieldAppliedAt)
        db.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
        db.set("",    forKey: EyeBreakKey.activeLayer)
    }
}
