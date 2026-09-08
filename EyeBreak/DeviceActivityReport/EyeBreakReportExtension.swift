// Layer 1 — DeviceActivityReport Extension
//
// 职责：读取 ActivitySegment.longestActivity（最长连续屏幕会话时长），
// 写入 App Group UserDefaults，供主 App 和 Monitor 扩展用于决策。
//
// ⚠️ 如果编译时出现 "type 'DeviceActivityResults' cannot conform to 'View'" 或
//    "value of type '(ForEach...)' has no member 'deviceActivityResults'"，
//    说明本版本 SDK 的 Environment Key 名称不同。
//    请在 Xcode 中 Option+点击 `DeviceActivityReport` 查看实际的
//    @Environment 或 @Query property wrapper。
//    核心逻辑（DateComponents 转换、UserDefaults 写入、触发判断）不变，
//    只需把数据源换成正确的属性即可。

import DeviceActivity
import SwiftUI

// MARK: - Context 标识符（与主 App 的 DeviceActivityReport(.eyeBreakActivity) 对应）

extension DeviceActivityReport.Context {
    static let eyeBreakActivity = Self(rawValue: "com.eyebreak.report.activity")
}

// MARK: - 扩展入口

@main
struct EyeBreakReportScene: DeviceActivityReportScene {
    var body: some DeviceActivityReportScene {
        EyeBreakActivityReport(context: .eyeBreakActivity)
    }
}

// MARK: - Report Scene（系统根据 context 匹配并调用）

struct EyeBreakActivityReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context

    var body: some View {
        EyeBreakDataExtractorView()
    }
}

// MARK: - 数据提取视图

struct EyeBreakDataExtractorView: View {

    // 系统通过此 Environment Key 将 DeviceActivityResults 注入视图。
    // 类型：AsyncSequence，每个元素是 DeviceActivityData。
    // 若编译失败，可能的替代属性名：
    //   @Environment(\.deviceActivityData) var activityResults
    //   @State var activityResults: DeviceActivityResults<DeviceActivityData>
    @Environment(\.deviceActivityResults) private var activityResults

    private let defaults = UserDefaults(suiteName: EyeBreakConfig.appGroupID)!

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .task {
                await extractAndPersist()
            }
    }

    // MARK: - DateComponents → TimeInterval

    private func seconds(from components: DateComponents) -> TimeInterval {
        let h = Double(components.hour   ?? 0) * 3600
        let m = Double(components.minute ?? 0) * 60
        let s = Double(components.second ?? 0)
        return h + m + s
    }

    // MARK: - 提取 longestActivity 并持久化

    private func extractAndPersist() async {
        var maxContinuousSeconds: TimeInterval = 0
        var totalSeconds: TimeInterval = 0

        for await data in activityResults {
            // activitySegments 是普通 Array，不需要 await
            for segment in data.activitySegments {
                // totalActivityDuration 类型：DateComponents（需转换为秒）
                totalSeconds += seconds(from: segment.totalActivityDuration)

                // longestActivity 类型：DateInterval?（.duration 返回 TimeInterval 秒数）
                if let longest = segment.longestActivity {
                    if longest.duration > maxContinuousSeconds {
                        maxContinuousSeconds = longest.duration
                    }
                }
            }
        }

        // 写入共享存储（主 App 每 3 秒同步，Monitor 扩展每次被唤醒时读取）
        defaults.set(maxContinuousSeconds, forKey: EyeBreakKey.longestActivitySeconds)
        defaults.set(totalSeconds,          forKey: EyeBreakKey.totalActivitySeconds)
        defaults.set(Date(),                forKey: EyeBreakKey.longestActivityUpdatedAt)

        // Layer 1 触发判断：30 分钟连续使用
        let threshold: TimeInterval = 30 * 60
        let inCooldown: Bool = {
            guard let until = defaults.object(forKey: EyeBreakKey.cooldownUntil) as? Date
            else { return false }
            return Date() < until
        }()

        if maxContinuousSeconds >= threshold,
           !inCooldown,
           !defaults.bool(forKey: EyeBreakKey.shouldShowEyeBreak) {
            defaults.set(true,  forKey: EyeBreakKey.shouldShowEyeBreak)
            defaults.set("1",   forKey: EyeBreakKey.activeLayer)
        }
    }
}
