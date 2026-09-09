// Layer 1 — DeviceActivityReport Extension
//
// 职责：读取 ActivitySegment 的 longestActivity / totalActivityDuration，
// 以及 DeviceActivityData 的 lastUpdatedDate（v0.4 第七节 POC 1 要求观测数据更新延迟），
// 写入 App Group 共享存储，供主 App 与 Monitor 扩展决策。
//
// 正确的扩展结构（由编译器错误反推得到）：
//   @main 挂在 DeviceActivityReportExtension 上，它的 body 返回若干 DeviceActivityReportScene；
//   每个 Scene 要求 context / Configuration / Content，
//   数据通过 makeConfiguration(representing:) 以 DeviceActivityResults 异步序列传入——
//   没有 @Environment(\.deviceActivityResults) 这种东西。
//
// ⚠️ 平台限制（重要）：
//    DeviceActivityReport 是 SwiftUI View，只有主 App 前台显示它时扩展才会渲染。
//    longestActivity 只在用户打开 EyeBreak 时刷新，用户在别的 App 里刷屏时不会更新。
//    因此 Layer 1 只作为「打开 App 时的校准信号」，
//    真正的后台触发依赖 Monitor 扩展的 Layer 2 递增阈值密度判定。
//    正因为数据可能陈旧，写入时必须带时间戳，消费方一律做新鲜度校验。

import DeviceActivity
import SwiftUI

extension DeviceActivityReport.Context {
    static let eyeBreakActivity = Self(rawValue: "com.eyebreak.report.activity")
}

// MARK: - 扩展入口

@main
struct EyeBreakReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        EyeBreakActivityReport { summary in
            EyeBreakSummaryView(summary: summary)
        }
    }
}

// MARK: - 提取结果

struct EyeBreakSummary {
    var longestSeconds: TimeInterval = 0
    var totalSeconds: TimeInterval = 0
    var segmentCount: Int = 0
    var appleLastUpdated: Date?
}

// MARK: - Scene

struct EyeBreakActivityReport: DeviceActivityReportScene {

    let context: DeviceActivityReport.Context = .eyeBreakActivity
    let content: (EyeBreakSummary) -> EyeBreakSummaryView

    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> EyeBreakSummary {

        var summary = EyeBreakSummary()

        for await activityData in data {
            // POC 1：系统最后一次更新该设备活动数据的时间
            let updated = activityData.lastUpdatedDate
            if summary.appleLastUpdated == nil || updated > summary.appleLastUpdated! {
                summary.appleLastUpdated = updated
            }

            for await segment in activityData.activitySegments {
                summary.segmentCount += 1
                summary.totalSeconds += segment.totalActivityDuration

                // 该片段内最长一次连续活动会话
                if let longest = segment.longestActivity {
                    summary.longestSeconds = max(summary.longestSeconds, longest.duration)
                }
            }
        }

        persist(summary)
        return summary
    }

    // MARK: 写入共享存储 + Layer 1 触发判断

    private func persist(_ summary: EyeBreakSummary) {
        let defaults = UserDefaults.eyeBreak
        defaults.eb_resetDailyStateIfNeeded()

        defaults.set(summary.longestSeconds, forKey: EyeBreakKey.longestActivitySeconds)
        defaults.set(summary.totalSeconds,   forKey: EyeBreakKey.totalActivitySeconds)
        defaults.set(summary.segmentCount,   forKey: EyeBreakKey.segmentCount)
        defaults.set(Date(),                 forKey: EyeBreakKey.longestActivityUpdatedAt)
        if let appleUpdated = summary.appleLastUpdated {
            defaults.set(appleUpdated, forKey: EyeBreakKey.appleLastUpdatedDate)
        }

        // 阈值从共享配置读取，与主 App / Monitor 完全一致
        let thresholdSeconds = Double(defaults.eb_targetMinutes * 60)
        guard summary.longestSeconds >= thresholdSeconds,
              !defaults.eb_inCooldown,
              !defaults.eb_alreadyTriggered
        else { return }

        defaults.set(true, forKey: EyeBreakKey.shouldShowEyeBreak)
        defaults.set("1",  forKey: EyeBreakKey.activeLayer)
    }
}

// MARK: - 渲染内容
//
// 主 App 把这个 Report 以 1×1 尺寸嵌入，只为触发扩展跑数据提取，
// 所以这里不需要真的画什么。

struct EyeBreakSummaryView: View {
    let summary: EyeBreakSummary

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
    }
}
