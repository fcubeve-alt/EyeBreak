import ManagedSettings
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

    // MARK: - Shared handler

    private func handleAction(_ action: ShieldAction,
                              completionHandler: @escaping (ShieldActionResponse) -> Void) {
        switch action {

        case .primaryButtonPressed:
            // 用户点"做护眼动作"：解除 Shield，让用户能切换到 EyeBreak 主 App。
            // 不覆盖 activeLayer——保留真正触发的那一层，否则 POC 记录会失真。
            defaults.set(true, forKey: EyeBreakKey.shouldShowEyeBreak)
            unblock()
            completionHandler(.close)

        case .secondaryButtonPressed:
            // 用户点"稍后再说"：解除 Shield，设冷却期，清空连续链
            let cooldown = Date().addingTimeInterval(Double(EyeBreakConfig.cooldownMinutes * 60))
            defaults.set(cooldown, forKey: EyeBreakKey.cooldownUntil)
            defaults.removeObject(forKey: EyeBreakKey.milestoneHits)
            defaults.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
            defaults.set("",    forKey: EyeBreakKey.activeLayer)
            unblock()
            completionHandler(.close)

        // 二级菜单项等其余动作一律按「稍后」处理：解除遮罩、放用户回去
        default:
            unblock()
            completionHandler(.close)
        }
    }

    private func unblock() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories   = nil
        defaults.removeObject(forKey: EyeBreakKey.shieldAppliedAt)
    }
}
