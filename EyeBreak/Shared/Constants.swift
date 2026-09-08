import Foundation

enum EyeBreakConfig {
    static let appGroupID = "group.com.eyebreak.shared"

    // Layer 2: rolling 5-min windows
    static let shortWindowMinutes: Int = 5
    static let activityThresholdMinutes: Int = 3   // 3+ min in 5-min window = "active"
    static let consecutiveWindowsNeeded: Int = 6   // 6 × 5min ≈ 30min
    static let maxGapMinutes: Int = 10             // gap > 10min → reset streak

    // Layer 3: daily total
    static let dailyTotalThresholdMinutes: Int = 30

    static let cooldownMinutes: Int = 15
}

enum EyeBreakKey {
    // Detection state (written by extensions, read by main app)
    static let longestActivitySeconds      = "eyebreak.longestActivitySeconds"
    static let longestActivityUpdatedAt    = "eyebreak.longestActivityUpdatedAt"
    static let totalActivitySeconds        = "eyebreak.totalActivitySeconds"
    static let consecutiveActiveWindows    = "eyebreak.consecutiveActiveWindows"
    static let lastActiveWindowEndTime     = "eyebreak.lastActiveWindowEndTime"
    static let activeLayer                 = "eyebreak.activeLayer"   // "1","2","3",""

    // Trigger / UX state
    static let shouldShowEyeBreak          = "eyebreak.shouldShowEyeBreak"
    static let cooldownUntil               = "eyebreak.cooldownUntil"
    static let eyeBreakCount               = "eyebreak.eyeBreakCount"
}

extension UserDefaults {
    static var eyeBreak: UserDefaults {
        UserDefaults(suiteName: EyeBreakConfig.appGroupID)!
    }
}
