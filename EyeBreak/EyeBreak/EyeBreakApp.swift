import SwiftUI
import FamilyControls
import UserNotifications

@main
struct EyeBreakApp: App {
    @StateObject private var manager = ScreenTimeManager()
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onAppear {
                    delegate.manager = manager
                    // -EyeBreakDemo：直接打开护眼界面，供模拟器截图与 UX 验收使用
                    if ProcessInfo.processInfo.arguments.contains("-EyeBreakDemo") {
                        manager.showEyeBreak = true
                    } else {
                        checkAndShowBreakIfNeeded()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification)) { _ in
                    checkAndShowBreakIfNeeded()
                }
        }
    }

    /// 进前台时同步一次：包含跨天重置、Shield 超时兜底、以及待处理的触发标志
    @MainActor
    private func checkAndShowBreakIfNeeded() {
        manager.syncFromDefaults()
    }
}

// MARK: - UIApplicationDelegate

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var manager: ScreenTimeManager?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        return true
    }

    // 前台收到通知时直接弹护眼界面（不显示横幅）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.categoryIdentifier == "EYEBREAK" {
            Task { @MainActor in manager?.showEyeBreak = true }
            completionHandler([])  // 不额外弹横幅，直接展示全屏界面
        } else {
            completionHandler([.banner, .sound])
        }
    }

    // 用户点击通知
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == "EYEBREAK" {
            Task { @MainActor in manager?.showEyeBreak = true }
        }
        completionHandler()
    }

    private func registerNotificationCategories() {
        let dismiss = UNNotificationAction(
            identifier: "DISMISS",
            title: "稍后再说",
            options: []
        )
        let exercise = UNNotificationAction(
            identifier: "EXERCISE",
            title: "做护眼动作",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "EYEBREAK",
            actions: [exercise, dismiss],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
