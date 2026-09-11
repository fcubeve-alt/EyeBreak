// DeviceActivityMonitor Extension
//
// Layer 1: 读取 Report 扩展写入的 longestActivity（带新鲜度校验）
// Layer 2: 递增阈值里程碑 + 使用密度判定「连续用屏」
// Layer 3: 45 分钟级日总量柔性提醒（v0.4 第五节 C 级）
//
// 为什么不是「数 5 分钟窗口」：
//   DeviceActivityEvent 的 threshold 在一个监测区间内只触发一次，不会重新武装，
//   而 DeviceActivitySchedule 的区间最短 15 分钟——5 分钟滚动窗口在 API 层面建不出来。
//   所以改为铺一排递增阈值，用相邻回调的真实时钟间隔算使用密度。
//   判定逻辑本身在 Shared/Detection.swift，是可单测的纯函数。

import DeviceActivity
import ManagedSettings
import UserNotifications
import Foundation

// MARK: - 名称

extension DeviceActivityName {
    static let eyeBreakUsage  = DeviceActivityName("com.eyebreak.monitor.usage")
    /// Shield 看门狗：应用遮罩时注册，到期由系统回调 intervalDidEnd 强制解除。
    static let shieldWatchdog = DeviceActivityName("com.eyebreak.monitor.shieldWatchdog")
}

extension DeviceActivityEvent.Name {
    static func milestone(_ minutes: Int) -> Self { Self("eyebreak.milestone.\(minutes)") }

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
        guard activity != .shieldWatchdog else { return }

        db.eb_resetDetectionState()
        db.set(UserDefaults.eb_dayString(Date()), forKey: EyeBreakKey.dayStamp)
        db.set(0, forKey: EyeBreakKey.completedCount)
        db.set(0, forKey: EyeBreakKey.skippedCount)
        db.set(0, forKey: EyeBreakKey.snoozedCount)
        releaseShieldIfStale()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        // 看门狗到期：无条件解除遮罩。这是不依赖用户操作的恢复通道。
        if activity == .shieldWatchdog {
            forceReleaseShield()
            return
        }
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

        // 无论是否冷却都要维护里程碑链，否则冷却结束后密度判定会失真
        recordMilestone(minutes: minutes, at: now)

        guard !db.eb_inCooldown, !db.eb_alreadyTriggered else { return }

        if checkLayer1() { return }
        if checkLayer2(currentMinutes: minutes, now: now) { return }
        checkLayer3(currentMinutes: minutes)
    }

    // MARK: - 里程碑记录（含「充分休息则重置」）

    private func recordMilestone(minutes: Int, at now: Date) {
        var chain = MilestoneChain.decode(
            db.dictionary(forKey: EyeBreakKey.milestoneHits) as? [String: Double]
        )

        let lastMinutes = db.integer(forKey: EyeBreakKey.lastMilestoneMinutes)
        if lastMinutes > 0,
           let lastAt = db.object(forKey: EyeBreakKey.lastMilestoneAt) as? Date,
           EyeBreakDetection.didRest(
               usageDeltaMinutes: Double(minutes - lastMinutes),
               wallDeltaMinutes: now.timeIntervalSince(lastAt) / 60,
               restGapMinutes: EyeBreakConfig.restGapMinutes
           ) {
            chain.removeAll()   // v0.3 Kill Test #1 场景 2/3：连续链重置
        }

        chain[minutes] = now
        db.set(MilestoneChain.encode(chain), forKey: EyeBreakKey.milestoneHits)
        db.set(minutes, forKey: EyeBreakKey.lastMilestoneMinutes)
        db.set(now, forKey: EyeBreakKey.lastMilestoneAt)
    }

    // MARK: - Layer 1

    private func checkLayer1() -> Bool {
        guard db.eb_layer1IsFresh else { return false }
        guard db.double(forKey: EyeBreakKey.longestActivitySeconds)
                >= Double(db.eb_targetMinutes * 60) else { return false }
        trigger(layer: "1")
        return true
    }

    // MARK: - Layer 2

    private func checkLayer2(currentMinutes: Int, now: Date) -> Bool {
        let target = db.eb_targetMinutes
        let chain = MilestoneChain.decode(
            db.dictionary(forKey: EyeBreakKey.milestoneHits) as? [String: Double]
        )

        let span = EyeBreakConfig.continuityUsageSpan(for: target)
        if let anchor = EyeBreakDetection.anchor(in: chain,
                                                 currentMinutes: currentMinutes,
                                                 spanMinutes: span) {
            db.set(EyeBreakDetection.density(
                usageDeltaMinutes: Double(currentMinutes - anchor.minutes),
                wallDeltaMinutes: now.timeIntervalSince(anchor.at) / 60
            ), forKey: EyeBreakKey.observedDensity)
        }

        guard EyeBreakDetection.isContinuous(hits: chain,
                                             currentMinutes: currentMinutes,
                                             now: now,
                                             targetMinutes: target) else { return false }
        trigger(layer: "2")
        return true
    }

    // MARK: - Layer 3

    private func checkLayer3(currentMinutes: Int) {
        guard EyeBreakDetection.shouldRemindLayer3(
            currentMinutes: currentMinutes,
            lastLayer3Milestone: db.integer(forKey: EyeBreakKey.lastLayer3Milestone),
            layer3Minutes: db.eb_layer3Minutes
        ) else { return }
        db.set(currentMinutes, forKey: EyeBreakKey.lastLayer3Milestone)
        trigger(layer: "3")
    }

    // MARK: - 触发

    private func trigger(layer: String) {
        db.set(true,   forKey: EyeBreakKey.shouldShowEyeBreak)
        db.set(layer,  forKey: EyeBreakKey.activeLayer)
        db.set(Date(), forKey: EyeBreakKey.shieldAppliedAt)

        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories   = .all()

        armShieldWatchdog()
        postTriggerNotification(layer: layer)
        postRecoveryNotification()
    }

    /// 注册一次性看门狗计划。到期后系统回调 intervalDidEnd，
    /// 即使用户从未再打开 App、ShieldAction 也从未运行，遮罩仍会被解除。
    private func armShieldWatchdog() {
        let cal = Calendar.current
        let now = Date()
        guard let end = cal.date(byAdding: .minute,
                                 value: EyeBreakConfig.shieldMaxMinutes,
                                 to: now) else { return }

        // 跨午夜会让 intervalEnd 早于 intervalStart，这种情况放弃看门狗，
        // 依赖其余恢复通道（下次扩展唤醒、打开 App、通知里的紧急解除）。
        guard cal.isDate(end, inSameDayAs: now) else { return }

        let schedule = DeviceActivitySchedule(
            intervalStart: cal.dateComponents([.hour, .minute, .second], from: now),
            intervalEnd:   cal.dateComponents([.hour, .minute, .second], from: end),
            repeats: false
        )
        try? DeviceActivityCenter().startMonitoring(.shieldWatchdog, during: schedule)
    }

    private func postTriggerNotification(layer: String) {
        let content = UNMutableNotificationContent()
        content.title = "眼睛需要休息了"
        content.body  = EyeBreakCopy.notificationBody(
            layer: layer,
            targetMinutes: db.eb_targetMinutes,
            layer3Minutes: db.eb_layer3Minutes
        )
        content.sound = .default
        content.categoryIdentifier = EyeBreakNotification.category

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "eyebreak-\(Int(Date().timeIntervalSince1970))",
                                  content: content,
                                  trigger: nil),
            withCompletionHandler: nil
        )
    }

    /// 在遮罩到期时间点投递一条带「立即解除」动作的通知。
    /// 该动作是非前台动作，系统会在后台唤起主 App 执行解除，
    /// 因此用户无需自己找到并打开 EyeBreak 就能恢复设备。
    private func postRecoveryNotification() {
        let content = UNMutableNotificationContent()
        content.title = "护眼提醒已结束"
        content.body  = "如果仍有应用被遮挡，点此立即解除。"
        content.sound = nil
        content.categoryIdentifier = EyeBreakNotification.categoryRecovery

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: Double(EyeBreakConfig.shieldMaxMinutes * 60),
            repeats: false
        )
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "eyebreak-recovery",
                                  content: content,
                                  trigger: trigger),
            withCompletionHandler: nil
        )
    }

    // MARK: - Shield 恢复

    private func releaseShieldIfStale() {
        guard db.eb_shieldIsStale else { return }
        forceReleaseShield()
    }

    private func forceReleaseShield() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories   = nil
        db.eb_clearTriggerState()
        DeviceActivityCenter().stopMonitoring([.shieldWatchdog])
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["eyebreak-recovery"])
    }
}
