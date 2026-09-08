// DeviceActivityMonitor Extension
// Layer 2: 5-min rolling window streak → detects ~30 min continuous use
// Layer 3: daily total threshold → heavy-user fallback
// Layer 1 check: opportunistically reads longestActivity written by Report extension

import DeviceActivity
import ManagedSettings
import UserNotifications
import Foundation

// MARK: - Activity / Event name extensions

extension DeviceActivityName {
    static let eyeBreakWindowed = DeviceActivityName("com.eyebreak.monitor.windowed")
    static let eyeBreakDaily    = DeviceActivityName("com.eyebreak.monitor.daily")
}

extension DeviceActivityEvent.Name {
    static let windowThreshold = DeviceActivityEvent.Name("eyebreak.windowThreshold")
    static let dailyThreshold  = DeviceActivityEvent.Name("eyebreak.dailyThreshold")
}

// MARK: - Monitor

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let store    = ManagedSettingsStore()
    private let defaults = UserDefaults(suiteName: EyeBreakConfig.appGroupID)!

    // ── intervalDidStart ────────────────────────────────────────────────────

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if activity == .eyeBreakWindowed {
            checkAndMaybeResetWindowStreak()
        }
        if activity == .eyeBreakDaily {
            defaults.set(0.0, forKey: EyeBreakKey.totalActivitySeconds)
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
    }

    // ── eventDidReachThreshold ───────────────────────────────────────────────

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)

        // Opportunistic Layer 1 check every time extension wakes up
        checkLayer1IfNeeded()
        guard !isInCooldown(), !alreadyTriggered() else { return }

        switch event {
        case .windowThreshold:
            handleWindowActive()
        case .dailyThreshold:
            let layer = defaults.string(forKey: EyeBreakKey.activeLayer) ?? ""
            if layer.isEmpty { trigger(layer: "3") }
        default:
            break
        }
    }

    // ── Layer 1: opportunistic check of longestActivity from Report extension ─

    private func checkLayer1IfNeeded() {
        guard !isInCooldown(), !alreadyTriggered() else { return }
        let longestSecs = defaults.double(forKey: EyeBreakKey.longestActivitySeconds)
        let thresholdSecs: Double = 30 * 60
        if longestSecs >= thresholdSecs {
            trigger(layer: "1")
        }
    }

    // ── Layer 2: rolling window streak ────────────────────────────────────────

    private func handleWindowActive() {
        checkAndMaybeResetWindowStreak()

        let updated = defaults.integer(forKey: EyeBreakKey.consecutiveActiveWindows) + 1
        defaults.set(updated, forKey: EyeBreakKey.consecutiveActiveWindows)

        // Mark expected end of this window so next intervalDidStart can detect gaps
        let windowEnd = Date().addingTimeInterval(Double(EyeBreakConfig.shortWindowMinutes * 60))
        defaults.set(windowEnd, forKey: EyeBreakKey.lastActiveWindowEndTime)

        if updated >= EyeBreakConfig.consecutiveWindowsNeeded {
            trigger(layer: "2")
            defaults.set(0, forKey: EyeBreakKey.consecutiveActiveWindows)
        }
    }

    private func checkAndMaybeResetWindowStreak() {
        let maxGapSecs = Double(EyeBreakConfig.maxGapMinutes * 60)
        guard let lastEnd = defaults.object(forKey: EyeBreakKey.lastActiveWindowEndTime) as? Date
        else { return }
        if Date().timeIntervalSince(lastEnd) > maxGapSecs {
            defaults.set(0, forKey: EyeBreakKey.consecutiveActiveWindows)
        }
    }

    // ── Trigger ──────────────────────────────────────────────────────────────

    private func trigger(layer: String) {
        defaults.set(true,  forKey: EyeBreakKey.shouldShowEyeBreak)
        defaults.set(layer, forKey: EyeBreakKey.activeLayer)

        // Shield: block all apps — user sees custom Shield when opening any app
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories   = .all()

        // Notification: backup for when Shield isn't visible yet
        let content                 = UNMutableNotificationContent()
        content.title               = "眼睛需要休息了"
        content.body                = "您已持续使用屏幕约30分钟，请做一下护眼动作。"
        content.sound               = .default
        content.categoryIdentifier  = "EYEBREAK"

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "eyebreak-\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            ),
            withCompletionHandler: nil
        )
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func isInCooldown() -> Bool {
        guard let until = defaults.object(forKey: EyeBreakKey.cooldownUntil) as? Date
        else { return false }
        return Date() < until
    }

    private func alreadyTriggered() -> Bool {
        defaults.bool(forKey: EyeBreakKey.shouldShowEyeBreak)
    }
}
