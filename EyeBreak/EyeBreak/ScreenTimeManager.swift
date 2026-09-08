import Foundation
import FamilyControls
import DeviceActivity
import ManagedSettings
import UserNotifications

// MARK: - Activity / Event name extensions (main app target)

extension DeviceActivityName {
    static let eyeBreakWindowed = DeviceActivityName("com.eyebreak.monitor.windowed")
    static let eyeBreakDaily    = DeviceActivityName("com.eyebreak.monitor.daily")
}

extension DeviceActivityEvent.Name {
    static let windowThreshold  = DeviceActivityEvent.Name("eyebreak.windowThreshold")
    static let dailyThreshold   = DeviceActivityEvent.Name("eyebreak.dailyThreshold")
}

// MARK: - Manager

@MainActor
class ScreenTimeManager: ObservableObject {

    // Auth
    @Published var authStatus: AuthorizationStatus = .notDetermined

    // Monitoring
    @Published var isMonitoring = false
    @Published var debugWindowMinutes = 2   // set low for testing; 5 for production

    // Layer 1 (longestActivity — written by DeviceActivityReport extension)
    @Published var longestActivityMinutes: Double = 0
    @Published var layer1UpdatedAt: Date?

    // Layer 2 (consecutive short windows)
    @Published var consecutiveWindows: Int = 0
    @Published var windowsNeeded: Int = EyeBreakConfig.consecutiveWindowsNeeded

    // Layer 3 (daily total)
    @Published var totalActivityMinutes: Double = 0

    // Active layer that triggered (or "")
    @Published var activeLayer: String = ""

    // Eye break
    @Published var showEyeBreak = false

    // Log
    @Published var log: [String] = []

    private let center = DeviceActivityCenter()
    private let store  = ManagedSettingsStore()
    private var refreshTimer: Timer?

    init() {
        authStatus = AuthorizationCenter.shared.authorizationStatus
        startRefreshTimer()
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            authStatus = AuthorizationCenter.shared.authorizationStatus
            addLog("授权：\(authStatus)")
            if authStatus == .approved {
                requestNotificationPermission()
            }
        } catch {
            addLog("授权失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Start monitoring (all three layers)

    func startMonitoring() {
        resetState()

        do {
            // ── Layer 2: 5-min rolling windows ───────────────────────────────
            // Each 24h interval with repeats=true + a threshold event.
            // The monitor extension tracks consecutive threshold-reached events.
            let windowSchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
                intervalEnd:   DateComponents(hour: 23, minute: 59, second: 59),
                repeats: true
            )
            let windowEvent = DeviceActivityEvent(
                applications: [],   // empty = all apps
                categories: [],
                webDomains: [],
                threshold: DateComponents(minute: max(1, debugWindowMinutes - 1))
            )
            try center.startMonitoring(
                .eyeBreakWindowed,
                during: windowSchedule,
                events: [.windowThreshold: windowEvent]
            )

            // ── Layer 3: daily total ─────────────────────────────────────────
            // Simple: fire once when total screen use hits 30 min today.
            let dailySchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
                intervalEnd:   DateComponents(hour: 23, minute: 59, second: 59),
                repeats: true
            )
            let dailyEvent = DeviceActivityEvent(
                applications: [],
                categories: [],
                webDomains: [],
                threshold: DateComponents(minute: 30)
            )
            try center.startMonitoring(
                .eyeBreakDaily,
                during: dailySchedule,
                events: [.dailyThreshold: dailyEvent]
            )

            isMonitoring = true
            addLog("监测已启动 — Layer 2 窗口阈值: \(max(1, debugWindowMinutes - 1))分钟 | Layer 3 日总量: 30分钟")
        } catch {
            addLog("启动失败：\(error.localizedDescription)")
        }
    }

    func stopMonitoring() {
        center.stopMonitoring([.eyeBreakWindowed, .eyeBreakDaily])
        isMonitoring = false
        addLog("监测已停止")
    }

    // MARK: - Eye break actions

    func manualTrigger() {
        addLog("手动触发")
        showEyeBreak = true
    }

    func dismissEyeBreak() {
        let until = Date().addingTimeInterval(Double(EyeBreakConfig.cooldownMinutes * 60))
        let db = UserDefaults.eyeBreak
        db.set(until, forKey: EyeBreakKey.cooldownUntil)
        db.set(0,     forKey: EyeBreakKey.consecutiveActiveWindows)
        db.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
        db.set("",    forKey: EyeBreakKey.activeLayer)
        unshield()
        showEyeBreak = false
        addLog("已关闭，冷却至 \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short))")
    }

    func completeEyeBreak() {
        let count = UserDefaults.eyeBreak.integer(forKey: EyeBreakKey.eyeBreakCount) + 1
        UserDefaults.eyeBreak.set(count, forKey: EyeBreakKey.eyeBreakCount)
        dismissEyeBreak()
        addLog("护眼完成 🎉 今日第 \(count) 次")
    }

    func unshield() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories   = nil
    }

    // MARK: - Private

    private func resetState() {
        let db = UserDefaults.eyeBreak
        db.set(0,      forKey: EyeBreakKey.consecutiveActiveWindows)
        db.set(false,  forKey: EyeBreakKey.shouldShowEyeBreak)
        db.set("",     forKey: EyeBreakKey.activeLayer)
        db.removeObject(forKey: EyeBreakKey.lastActiveWindowEndTime)
    }

    private func startRefreshTimer() {
        // Poll shared UserDefaults every 3 seconds to update the diagnostic UI
        // and catch triggers from extensions (which run in separate processes).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncFromDefaults() }
        }
    }

    private func syncFromDefaults() {
        let db = UserDefaults.eyeBreak

        longestActivityMinutes = db.double(forKey: EyeBreakKey.longestActivitySeconds) / 60
        layer1UpdatedAt        = db.object(forKey: EyeBreakKey.longestActivityUpdatedAt) as? Date
        totalActivityMinutes   = db.double(forKey: EyeBreakKey.totalActivitySeconds) / 60
        consecutiveWindows     = db.integer(forKey: EyeBreakKey.consecutiveActiveWindows)
        activeLayer            = db.string(forKey: EyeBreakKey.activeLayer) ?? ""

        // Layer 1 check: if longestActivity ≥ threshold and no cooldown
        let longestSecs = db.double(forKey: EyeBreakKey.longestActivitySeconds)
        let thresholdSecs = Double(debugWindowMinutes * 60)
        let notInCooldown: Bool = {
            guard let until = db.object(forKey: EyeBreakKey.cooldownUntil) as? Date else { return true }
            return Date() >= until
        }()
        if longestSecs >= thresholdSecs, notInCooldown, !db.bool(forKey: EyeBreakKey.shouldShowEyeBreak) {
            db.set(true,  forKey: EyeBreakKey.shouldShowEyeBreak)
            db.set("1",   forKey: EyeBreakKey.activeLayer)
            addLog("Layer 1 触发：longestActivity = \(String(format: "%.1f", longestSecs / 60)) 分钟")
        }

        // Show eye break if flagged
        if db.bool(forKey: EyeBreakKey.shouldShowEyeBreak), !showEyeBreak {
            showEyeBreak = true
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func addLog(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(ts)] \(msg)"
        log.append(entry)
        print("EyeBreak: \(entry)")
    }
}
