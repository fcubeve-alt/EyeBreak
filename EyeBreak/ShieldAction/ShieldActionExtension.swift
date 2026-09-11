import ManagedSettings
import DeviceActivity
import UserNotifications
import Foundation

class ShieldActionExtension: ShieldActionDelegate {

    private let store = ManagedSettingsStore()
    private var defaults: UserDefaults { UserDefaults.eyeBreak }

    override func handle(action: ShieldAction,
                         for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handleAction(action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction,
                         for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handleAction(action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction,
                         for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handleAction(action, completionHandler: completionHandler)
    }

    // MARK: - 统一处理

    private func handleAction(_ action: ShieldAction,
                              completionHandler: @escaping (ShieldActionResponse) -> Void) {
        switch action {

        case .primaryButtonPressed:
            // iOS 不允许 ShieldAction 扩展直接启动主 App，
            // 因此解除遮罩后立刻推一条带前台动作的通知，
            // 让用户一次点击就能进入护眼动作，而不是自己去找 App。
            defaults.set(true, forKey: EyeBreakKey.shouldShowEyeBreak)
            unblock()
            postOpenAppNotification()
            completionHandler(.close)

        case .secondaryButtonPressed:
            snooze()
            completionHandler(.close)

        // 二级菜单项等其余动作按「稍后」处理
        default:
            snooze()
            completionHandler(.close)
        }
    }

    private func snooze() {
        let cooldown = Date().addingTimeInterval(Double(EyeBreakConfig.cooldownMinutes * 60))
        defaults.set(cooldown, forKey: EyeBreakKey.cooldownUntil)
        defaults.removeObject(forKey: EyeBreakKey.milestoneHits)
        let count = defaults.integer(forKey: EyeBreakKey.snoozedCount) + 1
        defaults.set(count, forKey: EyeBreakKey.snoozedCount)
        defaults.eb_clearTriggerState()
        unblock()
    }

    private func postOpenAppNotification() {
        let content = UNMutableNotificationContent()
        content.title = "护眼动作准备好了"
        content.body  = "点此进入 EyeBreak，跟着做 20 秒。"
        content.sound = .default
        content.categoryIdentifier = EyeBreakNotification.category

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "eyebreak-open-\(Int(Date().timeIntervalSince1970))",
                                  content: content,
                                  trigger: nil),
            withCompletionHandler: nil
        )
    }

    private func unblock() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories   = nil
        defaults.removeObject(forKey: EyeBreakKey.shieldAppliedAt)
        DeviceActivityCenter().stopMonitoring([.shieldWatchdog])
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["eyebreak-recovery"])
    }
}

// MARK: - 看门狗活动名（与 Monitor 扩展一致）

extension DeviceActivityName {
    static let shieldWatchdog = DeviceActivityName("com.eyebreak.monitor.shieldWatchdog")
}
