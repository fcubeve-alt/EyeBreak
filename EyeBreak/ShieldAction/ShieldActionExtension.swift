import ManagedSettings
import Foundation

class ShieldActionExtension: ShieldActionDelegate {

    private let store    = ManagedSettingsStore()
    private let defaults = UserDefaults(suiteName: EyeBreakConfig.appGroupID)!

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
            // 用户点"做护眼动作"：解除 Shield，让用户能切换到 EyeBreak 主 App
            defaults.set(true, forKey: EyeBreakKey.shouldShowEyeBreak)
            defaults.set("1",  forKey: EyeBreakKey.activeLayer)
            unblock()
            completionHandler(.close)

        case .secondaryButtonPressed:
            // 用户点"稍后再说"：解除 Shield，设冷却期，重置连续计数
            let cooldown = Date().addingTimeInterval(Double(EyeBreakConfig.cooldownMinutes * 60))
            defaults.set(cooldown, forKey: EyeBreakKey.cooldownUntil)
            defaults.set(0,     forKey: EyeBreakKey.consecutiveActiveWindows)
            defaults.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
            defaults.set("",    forKey: EyeBreakKey.activeLayer)
            unblock()
            completionHandler(.close)

        @unknown default:
            unblock()
            completionHandler(.close)
        }
    }

    private func unblock() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories   = nil
    }
}
