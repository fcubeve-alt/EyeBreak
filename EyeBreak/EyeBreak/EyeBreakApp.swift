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
                        enterForeground()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification)) { _ in
                    enterForeground()
                }
        }
    }

    /// 进前台时同步一次：跨天重置、Shield 超时兜底、与系统核对监测状态、
    /// 以及处理待显示的触发标志。
    @MainActor
    private func enterForeground() {
        manager.reconcileMonitoringState()
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

    // 前台收到提醒时直接展示全屏护眼页，不再叠一层横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        switch notification.request.content.categoryIdentifier {
        case EyeBreakNotification.category:
            Task { @MainActor in self.manager?.showEyeBreak = true }
            completionHandler([])
        case EyeBreakNotification.categoryRecovery:
            // 已经在前台，说明 App 可运行，直接静默兜底解除
            Task { @MainActor in self.manager?.releaseShieldIfStale() }
            completionHandler([])
        default:
            completionHandler([.banner, .sound])
        }
    }

    // 用户对通知采取动作。必须按 actionIdentifier 分流，
    // 否则「稍后再说」会和「做护眼动作」走同一条路径。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier

        Task { @MainActor in
            guard let manager = self.manager else { return }

            switch action {
            case EyeBreakNotification.actionDismiss:
                // 稍后：设冷却、清理待显示状态、解除遮罩，且不打开护眼页
                manager.finishEyeBreak(.snoozed)

            case EyeBreakNotification.actionRelease:
                manager.emergencyRelease()

            case EyeBreakNotification.actionExercise:
                manager.showEyeBreak = true

            case UNNotificationDefaultActionIdentifier:
                // 点通知主体：提醒类打开护眼页，恢复类执行兜底解除
                if category == EyeBreakNotification.categoryRecovery {
                    manager.releaseShieldIfStale()
                } else {
                    manager.showEyeBreak = true
                }

            default:
                break   // 包含 UNNotificationDismissActionIdentifier：划掉通知不做任何事
            }
            completionHandler()
        }
    }

    private func registerNotificationCategories() {
        let exercise = UNNotificationAction(
            identifier: EyeBreakNotification.actionExercise,
            title: "做护眼动作",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: EyeBreakNotification.actionDismiss,
            title: "稍后再说",
            options: []
        )
        let breakCategory = UNNotificationCategory(
            identifier: EyeBreakNotification.category,
            actions: [exercise, dismiss],
            intentIdentifiers: [],
            options: []
        )

        // 紧急解除是非前台动作：系统会在后台唤起 App 执行，
        // 用户不必自己找到并打开 EyeBreak 就能恢复被遮挡的应用。
        let release = UNNotificationAction(
            identifier: EyeBreakNotification.actionRelease,
            title: "立即解除遮罩",
            options: []
        )
        let recoveryCategory = UNNotificationCategory(
            identifier: EyeBreakNotification.categoryRecovery,
            actions: [release],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current()
            .setNotificationCategories([breakCategory, recoveryCategory])
    }
}
